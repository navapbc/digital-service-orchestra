#!/usr/bin/env bash
# tests/scripts/test-check-hook-integrity.sh
# Tests for plugins/dso/scripts/check-hook-integrity.sh
#
# The integrity check makes silent fail-open degradation of the enforcement
# hooks VISIBLE. Running it on the real tree here means: if a committed change
# breaks/removes/chmod-strips any load-bearing enforcement hook, this test fails
# in CI (Script Tests) — turning "silently no enforcement" into a red build.
#
# Usage: bash tests/scripts/test-check-hook-integrity.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/plugins/dso/scripts/check-hook-integrity.sh"
REAL_HOOKS="$REPO_ROOT/plugins/dso/hooks"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-check-hook-integrity.sh ==="

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hook-integrity-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Fresh copy of the real hooks/ tree into the fixture, returns its path.
_fresh_fixture() {
    local dst="$WORK/fixture-$1/hooks"
    mkdir -p "$(dirname "$dst")"
    cp -R "$REAL_HOOKS" "$dst"
    echo "$dst"
}

# Run the check against a hooks dir; echo "exit|stderr".
_run_check() {
    local hooks_dir="$1" rc=0 err
    err=$(DSO_HOOK_INTEGRITY_HOOKS_DIR="$hooks_dir" bash "$CHECK" 2>&1 1>/dev/null) || rc=$?
    echo "${rc}|${err}"
}

# ── Test 1: the REAL tree passes (this is the CI enforcement signal) ─────────
_snapshot_fail
real_rc=0
DSO_HOOK_INTEGRITY_HOOKS_DIR="$REAL_HOOKS" bash "$CHECK" >/dev/null 2>&1 || real_rc=$?
assert_eq "test_real_hooks_tree_passes" "0" "$real_rc"
assert_pass_if_clean "test_real_hooks_tree_passes"

# ── Test 2: a clean copy passes (fixture sanity) ─────────────────────────────
_snapshot_fail
fx="$(_fresh_fixture clean)"
res="$(_run_check "$fx")"; rc="${res%%|*}"
assert_eq "test_clean_fixture_passes" "0" "$rc"
assert_pass_if_clean "test_clean_fixture_passes"

# ── Test 3: a MISSING direct hook fails (exit 1, reports missing) ────────────
_snapshot_fail
fx="$(_fresh_fixture missing)"
rm -f "$fx/dispatchers/pre-bash.sh"
res="$(_run_check "$fx")"; rc="${res%%|*}"; err="${res#*|}"
assert_eq "test_missing_direct_hook_fails" "1" "$rc"
assert_contains "test_missing_direct_hook_reports_missing" "missing" "$err"
assert_pass_if_clean "test_missing_direct_hook_fails"

# ── Test 4: a NON-EXECUTABLE direct hook fails (silent fail-open risk) ────────
_snapshot_fail
fx="$(_fresh_fixture noexec)"
chmod -x "$fx/run-hook.sh"
if [[ -x "$fx/run-hook.sh" ]]; then
    echo "SKIP: test_nonexec_direct_hook_fails (chmod -x had no effect, likely root)"
    assert_pass_if_clean "test_nonexec_direct_hook_fails"
else
    res="$(_run_check "$fx")"; rc="${res%%|*}"; err="${res#*|}"
    assert_eq "test_nonexec_direct_hook_fails" "1" "$rc"
    assert_contains "test_nonexec_direct_hook_reports_exec" "not executable" "$err"
    assert_pass_if_clean "test_nonexec_direct_hook_fails"
fi

# ── Test 5: a SYNTAX ERROR in a sourced hook fails (exit 1, reports syntax) ──
_snapshot_fail
fx="$(_fresh_fixture syntax)"
printf '\nif then fi (((\n' >> "$fx/lib/deps.sh"
res="$(_run_check "$fx")"; rc="${res%%|*}"; err="${res#*|}"
assert_eq "test_syntax_error_sourced_hook_fails" "1" "$rc"
assert_contains "test_syntax_error_sourced_hook_reports_syntax" "syntax error" "$err"
assert_pass_if_clean "test_syntax_error_sourced_hook_fails"

print_summary
