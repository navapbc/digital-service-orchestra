#!/usr/bin/env bash
set -euo pipefail
# scripts/write-reviewer-findings.sh
#
# Validate-then-write gate for reviewer-findings.json.
#
# Validates the JSON schema BEFORE writing to the canonical findings file.
# Only outputs the SHA-256 hash on success — making it mechanically impossible
# to obtain a valid REVIEWER_HASH without passing schema validation.
#
# Usage:
#   cat findings.json | "${CLAUDE_PLUGIN_ROOT}/scripts/write-reviewer-findings.sh"
#   cat findings.json | "${CLAUDE_PLUGIN_ROOT}/scripts/write-reviewer-findings.sh" --output /path/to/slot.json
#
#   Or with a heredoc:
#   cat <<'EOF' | "${CLAUDE_PLUGIN_ROOT}/scripts/write-reviewer-findings.sh"
#   { "scores": {...}, "findings": [...], "summary": "..." }
#   EOF
#
# Options:
#   --output <path>  Write findings to <path> instead of the canonical reviewer-findings.json.
#                    Used by deep tier parallel sonnet agents to write to slot-specific paths.
#   FINDINGS_OUTPUT env var is also accepted as a fallback (--output takes precedence).
#
# Exit codes:
#   0 = valid; findings written; SHA-256 hash printed to stdout
#   1 = schema validation failed; errors printed to stderr; nothing written
#   2 = usage error (no stdin, missing dependency)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Use get_artifacts_dir() for config-driven artifact directory
source "$PLUGIN_ROOT/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

# Parse --output flag (or FINDINGS_OUTPUT env var) for slot-specific output path
_OUTPUT_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) _OUTPUT_PATH="${2:?--output requires a path argument}"; shift 2 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
_OUTPUT_PATH="${_OUTPUT_PATH:-${FINDINGS_OUTPUT:-}}"

FINDINGS_FILE="${_OUTPUT_PATH:-$ARTIFACTS_DIR/reviewer-findings.json}"
PENDING_FILE="$ARTIFACTS_DIR/reviewer-findings-pending.json"

# Require piped input (no interactive use)
if [ -t 0 ]; then
    echo "ERROR: No input provided. Pipe JSON to this script." >&2
    echo "Usage: cat findings.json | $0" >&2
    exit 2
fi

# Write to pending file (not the canonical location yet)
cat > "$PENDING_FILE"

if [ ! -s "$PENDING_FILE" ]; then
    echo "ERROR: Empty input — no JSON received." >&2
    rm -f "$PENDING_FILE"
    exit 2
fi

# Validate schema BEFORE writing to canonical location.
# If validation fails, pending file is removed and the sub-agent cannot obtain a hash.
if ! "$SCRIPT_DIR/validate-review-output.sh" code-review-dispatch "$PENDING_FILE" >&2; then
    rm -f "$PENDING_FILE"
    echo "ERROR: Fix the JSON and re-run write-reviewer-findings.sh." >&2
    exit 1
fi

# Validation passed — promote pending to canonical and output hash
mv "$PENDING_FILE" "$FINDINGS_FILE"
shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}'
