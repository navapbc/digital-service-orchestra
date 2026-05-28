#!/usr/bin/env bash
# tests/scripts/test-check-hooks-doc.sh
# Behavioral tests for plugins/dso/scripts/check-hooks-doc.sh
#
# Tests cover:
#  - live repo (post-PR-E baseline) -> exit 0
#  - injected wrapper file (no doc) -> exit 1 with the wrapper name in stderr
#
# Usage: bash tests/scripts/test-check-hooks-doc.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: GREEN

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-hooks-doc.sh"
HOOKS_DIR="$PLUGIN_ROOT/plugins/dso/hooks"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-hooks-doc.sh ==="

# ── test_live_repo_clean ──────────────────────────────────────────────────────
test_live_repo_clean() {
    _snapshot_fail
    local rc=0
    bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
    assert_eq "test_live_repo_clean: post-PR-E baseline has zero hook-doc drift" "0" "$rc"
    assert_pass_if_clean "test_live_repo_clean"
}

# ── test_undocumented_wrapper_flagged ─────────────────────────────────────────
test_undocumented_wrapper_flagged() {
    _snapshot_fail
    # Inject a synthetic wrapper file (no doc row). Trap-cleanup ensures the
    # fixture is removed on SIGINT or normal function return (without the trap
    # a leaked file would cascade and fail subsequent pre-commit invocations
    # of check-hooks-doc.sh).
    local _hook_name="test-injected-undocumented-hook-$$"
    local _hook_file="$HOOKS_DIR/$_hook_name.sh"
    local stderr_file
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/test-check-hooks-doc-undoc.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$_hook_file' '$stderr_file'" RETURN
    printf '%s\n' "#!/usr/bin/env bash" "# Synthetic test fixture — should be flagged by check-hooks-doc" "exit 0" > "$_hook_file"
    chmod +x "$_hook_file"
    local rc=0
    bash "$SCRIPT" >/dev/null 2>"$stderr_file" || rc=$?
    local stderr_content
    stderr_content=$(cat "$stderr_file")
    assert_eq "test_undocumented_wrapper_flagged: exit 1 when a wrapper has no doc" "1" "$rc"
    if echo "$stderr_content" | grep -qF "$_hook_name.sh"; then
        echo "  PASS: test_undocumented_wrapper_flagged: stderr names the undocumented hook"
        (( PASS++ ))
    else
        echo "  FAIL: test_undocumented_wrapper_flagged: stderr did not name '$_hook_name.sh'" >&2
        echo "  Actual stderr: $stderr_content" >&2
        (( FAIL++ ))
    fi
    assert_pass_if_clean "test_undocumented_wrapper_flagged"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_live_repo_clean
test_undocumented_wrapper_flagged

print_summary
