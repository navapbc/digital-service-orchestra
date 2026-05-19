#!/usr/bin/env bash
# tests/scripts/test-record-review-symlink-invocation.sh
#
# Regression test for bug 654e-7314-2d10-42c1.
#
# plugins/dso/scripts/record-review.sh is a symlink to ../hooks/record-review.sh.
# When bash invokes the script via the symlink path, BASH_SOURCE[0] is the
# symlink path itself and `cd "$(dirname ...)"` yields plugins/dso/scripts/,
# NOT the canonical plugins/dso/hooks/. Before the fix, the script then tried
# to source `$HOOK_DIR/lib/deps.sh` = plugins/dso/scripts/lib/deps.sh — which
# does not exist (the libraries live at plugins/dso/hooks/lib/).
#
# This test asserts both invocation paths succeed at the source-statements
# phase. We don't need a full execution — the script's own usage error
# ("ERROR: unknown argument: --help") is sufficient to prove the source
# lines all ran (otherwise the failure would be a path error from the source
# statement, which exits before the usage check).
#
# Pre-existing tests at tests/hooks/test-record-review.sh always invoke via
# the canonical plugins/dso/hooks/ path, so they did not catch the bug.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
CANONICAL="$DSO_PLUGIN_DIR/hooks/record-review.sh"
SYMLINK="$DSO_PLUGIN_DIR/scripts/record-review.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-record-review-symlink-invocation.sh ==="

# Both files must be present for the test to be meaningful.
if [[ ! -f "$CANONICAL" ]]; then
    (( ++FAIL ))
    echo "FAIL: canonical record-review.sh missing at $CANONICAL" >&2
    print_summary
fi
if [[ ! -L "$SYMLINK" ]] && [[ ! -f "$SYMLINK" ]]; then
    (( ++FAIL ))
    echo "FAIL: scripts/record-review.sh missing at $SYMLINK (expected: symlink to ../hooks/record-review.sh)" >&2
    print_summary
fi

# Run via each invocation path. We expect:
#   - exit 0 from the script (it argparses --help and emits a "unknown argument" usage)
#   - stderr contains the usage line ("Usage: record-review.sh")
#   - stderr does NOT contain "No such file or directory" (the bug's signature)
# Run with CLAUDE_PLUGIN_ROOT unset so the script must compute it from HOOK_DIR.
run_check() {
    local label="$1" target="$2"
    local _stderr _rc
    _stderr=$(env -u CLAUDE_PLUGIN_ROOT bash "$target" --help 2>&1 1>/dev/null) || true
    if echo "$_stderr" | grep -q "No such file or directory"; then
        assert_eq "${label}:no_path_error" "0" "1"
        printf "  stderr: %s\n" "$_stderr" >&2
    else
        assert_eq "${label}:no_path_error" "0" "0"
    fi
    if echo "$_stderr" | grep -q "Usage: record-review.sh"; then
        assert_eq "${label}:reached_argparse" "0" "0"
    else
        assert_eq "${label}:reached_argparse" "0" "1"
        printf "  stderr: %s\n" "$_stderr" >&2
    fi
}

run_check "test_canonical_path_loads_libs" "$CANONICAL"
run_check "test_symlink_path_loads_libs" "$SYMLINK"

print_summary
