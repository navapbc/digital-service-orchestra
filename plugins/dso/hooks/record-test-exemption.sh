#!/usr/bin/env bash
# hooks/record-test-exemption.sh
# Proves a test is inherently slow and records an exemption.
#
# Runs the given test under a 60-second timeout. If the test EXCEEDS the
# timeout (exit 124), writes an exemption entry. If the test completes
# within 60s, exits non-zero (test is not eligible).
#
# Exemption file: $(get_artifacts_dir)/test-exemptions
# Format (pipe-delimited): node_id=<id>|threshold=60|timestamp=<ISO8601-UTC>
# Idempotent: overwrites existing entry for same node_id.
#
# Environment:
#   RECORD_TEST_EXEMPTION_RUNNER  — override test runner (for testing)
#   WORKFLOW_PLUGIN_ARTIFACTS_DIR — override artifacts dir (for testing)
#   CLAUDE_PLUGIN_ROOT            — DSO plugin root

set -euo pipefail

# Source shared dependency library (provides get_artifacts_dir, get_timeout_cmd)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# --- Argument validation ---
if [[ $# -lt 1 ]] || [[ -z "${1:-}" ]]; then
    echo "ERROR: missing test node id" >&2
    echo "" >&2
    echo "Usage: record-test-exemption.sh <test-node-id>" >&2
    exit 1
fi

NODE_ID="$1"

# --- Resolve artifacts directory ---
ARTIFACTS_DIR=$(get_artifacts_dir) || {
    echo "ERROR: could not resolve artifacts directory" >&2
    exit 1
}

# Ensure artifacts dir is writable
if ! mkdir -p "$ARTIFACTS_DIR" 2>/dev/null; then
    echo "ERROR: cannot create artifacts directory: $ARTIFACTS_DIR" >&2
    exit 1
fi

if ! test -w "$ARTIFACTS_DIR" 2>/dev/null; then
    echo "ERROR: artifacts directory is not writable: $ARTIFACTS_DIR" >&2
    exit 1
fi

EXEMPTIONS_FILE="$ARTIFACTS_DIR/test-exemptions"

# --- Run the test under a 60s timeout ---
TIMEOUT_SECONDS=60
exit_code=0

if [[ -n "${RECORD_TEST_EXEMPTION_RUNNER:-}" ]]; then
    # Use overridden runner (for testing)
    "$RECORD_TEST_EXEMPTION_RUNNER" "$NODE_ID" || exit_code=$?
else
    # Use timeout command to enforce the time limit
    TIMEOUT_CMD=$(get_timeout_cmd) || TIMEOUT_CMD=""
    if [[ -n "$TIMEOUT_CMD" ]]; then
        $TIMEOUT_CMD "$TIMEOUT_SECONDS" bash -c "cd \"\$(git rev-parse --show-toplevel)\" && python3 -m pytest \"$NODE_ID\" --tb=short -q -p no:cacheprovider 2>&1" || exit_code=$?
    else
        echo "WARNING: no timeout command available, running without timeout" >&2
        bash -c "cd \"\$(git rev-parse --show-toplevel)\" && python3 -m pytest \"$NODE_ID\" --tb=short -q -p no:cacheprovider 2>&1" || exit_code=$?
    fi
fi

# --- Evaluate result ---
# Exit code 124 = timeout (GNU coreutils timeout convention)
if [[ $exit_code -ne 124 ]]; then
    echo "ERROR: test completed within ${TIMEOUT_SECONDS}s — not eligible for exemption" >&2
    exit 1
fi

# --- Write exemption entry (idempotent) ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [[ -f "$EXEMPTIONS_FILE" ]]; then
    # Filter out any existing entry block for this node_id
    # Entry blocks are 3 consecutive lines: node_id=, threshold=, timestamp=
    # Remove the node_id line and the two lines that follow it
    FILTERED=$(python3 -c "
import sys, re
lines = open(sys.argv[1]).readlines()
target = 'node_id=' + sys.argv[2]
result = []
skip = 0
for line in lines:
    if skip > 0:
        skip -= 1
        continue
    if line.rstrip() == target:
        skip = 2  # skip threshold + timestamp lines
        continue
    result.append(line)
sys.stdout.write(''.join(result))
" "$EXEMPTIONS_FILE" "$NODE_ID" 2>/dev/null || cat "$EXEMPTIONS_FILE")
    if [[ -n "$FILTERED" ]]; then
        printf '%s' "$FILTERED" > "$EXEMPTIONS_FILE"
    else
        : > "$EXEMPTIONS_FILE"
    fi
fi

# Write entry fields on separate lines for parseability
# The node_id line serves as the entry key for idempotency checks
cat >> "$EXEMPTIONS_FILE" <<EOF
node_id=${NODE_ID}
threshold=${TIMEOUT_SECONDS}
timestamp=${TIMESTAMP}
EOF

echo "Exemption recorded: node_id=${NODE_ID} (threshold=${TIMEOUT_SECONDS}s)" >&2
exit 0
