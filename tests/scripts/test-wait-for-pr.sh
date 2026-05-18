#!/usr/bin/env bash
# tests/scripts/test-wait-for-pr.sh
# Tests for plugins/dso/scripts/wait-for-pr.sh.
#
# Strategy: a stub gh script is injected via GH_CMD. Each test seeds a fixture
# file with the JSON payload the stub should emit, and verifies the wait
# script's exit code and stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WAIT="$REPO_ROOT/plugins/dso/scripts/wait-for-pr.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

TMPDIR_T=$(mktemp -d /tmp/test-wait-for-pr.XXXXXX)
trap 'rm -rf "$TMPDIR_T"' EXIT

# Stub gh that prints the contents of $TMPDIR_T/payload.json when invoked.
cat > "$TMPDIR_T/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
# Usage: stub gh — emits $TMPDIR_T/payload.json regardless of args.
if [[ -f "$TMPDIR_T/payload.json" ]]; then
    cat "$TMPDIR_T/payload.json"
fi
EOF
chmod +x "$TMPDIR_T/gh-stub.sh"

export TMPDIR_T
export GH_CMD="$TMPDIR_T/gh-stub.sh"

# --- merged on first poll → exit 0 ---
cat > "$TMPDIR_T/payload.json" <<'EOF'
{"state":"MERGED","mergedAt":"2026-05-18T08:00:00Z","statusCheckRollup":[],"autoMergeRequest":null}
EOF
EXIT=0
bash "$WAIT" 123 --interval=1 --timeout=5 >/dev/null 2>&1 || EXIT=$?
assert_eq "merged_state_exits_0" "0" "$EXIT"

# --- closed without merge → exit 1 ---
cat > "$TMPDIR_T/payload.json" <<'EOF'
{"state":"CLOSED","mergedAt":null,"statusCheckRollup":[],"autoMergeRequest":null}
EOF
EXIT=0
bash "$WAIT" 123 --interval=1 --timeout=5 >/dev/null 2>&1 || EXIT=$?
assert_eq "closed_state_exits_1" "1" "$EXIT"

# --- failed required check → exit 1 ---
cat > "$TMPDIR_T/payload.json" <<'EOF'
{"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"name":"Script Tests","conclusion":"FAILURE","status":"COMPLETED"}],"autoMergeRequest":{"enabledAt":"2026-05-18T08:00:00Z"}}
EOF
EXIT=0
bash "$WAIT" 123 --interval=1 --timeout=5 >/dev/null 2>&1 || EXIT=$?
assert_eq "failed_check_exits_1" "1" "$EXIT"

# --- cancelled check → exit 1 ---
cat > "$TMPDIR_T/payload.json" <<'EOF'
{"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"name":"CI","conclusion":"CANCELLED","status":"COMPLETED"}],"autoMergeRequest":null}
EOF
EXIT=0
bash "$WAIT" 123 --interval=1 --timeout=5 >/dev/null 2>&1 || EXIT=$?
assert_eq "cancelled_check_exits_1" "1" "$EXIT"

# --- pending (no terminal signal) → timeout → exit 1 ---
cat > "$TMPDIR_T/payload.json" <<'EOF'
{"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"name":"CI","conclusion":null,"status":"IN_PROGRESS"}],"autoMergeRequest":null}
EOF
START=$(date +%s)
EXIT=0
bash "$WAIT" 123 --interval=1 --timeout=2 >/dev/null 2>&1 || EXIT=$?
END=$(date +%s)
assert_eq "pending_timeout_exits_1" "1" "$EXIT"
# Verify it actually waited (~2s), not bailed instantly
ELAPSED=$(( END - START ))
if [[ $ELAPSED -ge 2 ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: pending_waited_for_timeout: elapsed=%ds (expected >= 2)\n" "$ELAPSED" >&2
fi

# --- usage errors ---
EXIT=0
bash "$WAIT" >/dev/null 2>&1 || EXIT=$?
assert_eq "no_pr_arg_exits_2" "2" "$EXIT"

EXIT=0
bash "$WAIT" not-a-number >/dev/null 2>&1 || EXIT=$?
assert_eq "non_numeric_pr_exits_2" "2" "$EXIT"

EXIT=0
bash "$WAIT" 1 --interval=abc >/dev/null 2>&1 || EXIT=$?
assert_eq "non_numeric_interval_exits_2" "2" "$EXIT"

print_summary
