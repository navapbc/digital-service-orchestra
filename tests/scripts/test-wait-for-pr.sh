#!/usr/bin/env bash
# tests/scripts/test-wait-for-pr.sh
# Tests for plugins/dso/scripts/wait-for-pr.sh.
#
# Strategy: a stub gh script is injected via GH_CMD. Each test seeds a fixture
# file with the JSON payload the stub should emit, and verifies the wait
# script's exit code and stderr.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WAIT="$REPO_ROOT/plugins/dso/scripts/wait-for-pr.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

TMPDIR_T=$(mktemp -d "${TMPDIR:-/tmp}/test-wait-for-pr.XXXXXX")
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

# --- auto-merge transition: queued then disabled → exit 1 ---
# Use a sequence stub: first call returns autoMerge queued; second call returns
# autoMerge=null (disabled). _ever_had_auto must flip and trigger the exit.
cat > "$TMPDIR_T/seq-counter" <<'EOF'
0
EOF
cat > "$TMPDIR_T/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
N=$(cat "$TMPDIR_T/seq-counter")
echo "$((N+1))" > "$TMPDIR_T/seq-counter"
if [[ "$N" == "0" ]]; then
    # first poll: auto-merge queued
    echo '{"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"name":"CI","conclusion":null,"status":"IN_PROGRESS"}],"autoMergeRequest":{"enabledAt":"2026-05-18T09:00:00Z"}}'
else
    # subsequent poll: auto-merge disabled (null)
    echo '{"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"name":"CI","conclusion":null,"status":"IN_PROGRESS"}],"autoMergeRequest":null}'
fi
EOF
chmod +x "$TMPDIR_T/gh-stub.sh"
EXIT=0
bash "$WAIT" 123 --interval=1 --timeout=5 >/dev/null 2>&1 || EXIT=$?
assert_eq "auto_merge_disabled_exits_1" "1" "$EXIT"

# --- auto-merge was never queued (always null) → not flagged as disabled, just times out ---
cat > "$TMPDIR_T/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$TMPDIR_T/payload.json" ]]; then cat "$TMPDIR_T/payload.json"; fi
EOF
chmod +x "$TMPDIR_T/gh-stub.sh"
cat > "$TMPDIR_T/payload.json" <<'EOF'
{"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"name":"CI","conclusion":null,"status":"IN_PROGRESS"}],"autoMergeRequest":null}
EOF
START=$(date +%s)
EXIT=0
bash "$WAIT" 123 --interval=1 --timeout=2 >/dev/null 2>&1 || EXIT=$?
END=$(date +%s)
ELAPSED=$(( END - START ))
assert_eq "auto_merge_never_set_does_not_trigger" "1" "$EXIT"
if [[ $ELAPSED -ge 2 ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: auto_merge_never_set_waited: elapsed=%ds (expected >= 2)\n" "$ELAPSED" >&2
fi

# --- transient empty output → retry path ---
# First N polls return empty; the (N+1)th returns MERGED. Verifies the retry
# loop does not bail on transient empty output.
cat > "$TMPDIR_T/seq-counter" <<'EOF'
0
EOF
cat > "$TMPDIR_T/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
N=$(cat "$TMPDIR_T/seq-counter")
echo "$((N+1))" > "$TMPDIR_T/seq-counter"
if [[ "$N" -lt "1" ]]; then
    # first poll: empty output, zero exit (transient)
    exit 0
else
    echo '{"state":"MERGED","mergedAt":"2026-05-18T08:00:00Z","statusCheckRollup":[],"autoMergeRequest":null}'
fi
EOF
chmod +x "$TMPDIR_T/gh-stub.sh"
EXIT=0
bash "$WAIT" 123 --interval=1 --timeout=5 >/dev/null 2>&1 || EXIT=$?
assert_eq "transient_empty_then_merged_exits_0" "0" "$EXIT"

# --- fatal gh error (auth) → exit 1 immediately (no timeout) ---
cat > "$TMPDIR_T/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "HTTP 401: Bad credentials" >&2
exit 1
EOF
chmod +x "$TMPDIR_T/gh-stub.sh"
START=$(date +%s)
EXIT=0
bash "$WAIT" 123 --interval=5 --timeout=60 >/dev/null 2>&1 || EXIT=$?
END=$(date +%s)
ELAPSED=$(( END - START ))
assert_eq "fatal_gh_error_exits_1" "1" "$EXIT"
# Must NOT wait for timeout — should fail fast (< 5s).
if [[ $ELAPSED -lt 5 ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: fatal_gh_error_fast_exit: elapsed=%ds (expected < 5)\n" "$ELAPSED" >&2
fi

# --- non-fatal gh error → retry (transient) ---
cat > "$TMPDIR_T/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
# Simulate a transient error: print a non-fatal stderr message and exit 1
echo "network timeout, will retry" >&2
exit 1
EOF
chmod +x "$TMPDIR_T/gh-stub.sh"
START=$(date +%s)
EXIT=0
bash "$WAIT" 123 --interval=1 --timeout=2 >/dev/null 2>&1 || EXIT=$?
END=$(date +%s)
ELAPSED=$(( END - START ))
assert_eq "transient_gh_error_retries_until_timeout" "1" "$EXIT"
if [[ $ELAPSED -ge 2 ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: transient_gh_error_waited: elapsed=%ds (expected >= 2)\n" "$ELAPSED" >&2
fi

print_summary
