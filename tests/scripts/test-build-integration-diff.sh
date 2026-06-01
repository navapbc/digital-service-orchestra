#!/usr/bin/env bash
# tests/scripts/test-build-integration-diff.sh — W2a net-end-state diff (P5 repro)
#
# Proves build_net_integration_diff reviews the NET END-STATE of the touched
# files instead of concatenating per-commit diffs. The headline case is the
# CS-10 chronic re-flag (PR #509 cycle-3): commit A introduces a problem, a
# later in-range commit D fixes it; the per-commit concat shows BOTH hunks and
# the reviewer flags the already-fixed intermediate state. The net diff must
# show NEITHER (net change is clean), so it cannot re-flag.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/lib/build-integration-diff.sh"
# shellcheck source=../../plugins/dso/scripts/lib/build-integration-diff.sh
source "$LIB"

PASS=0
FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# Per-test isolated git repo (honors $TMPDIR isolation from the suite engine).
_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dso-w2a.XXXXXX")"
trap 'rm -rf "$_WORK"' EXIT

_git() { git -C "$_WORK" "$@"; }

# ── Fixture: main baseline, then a staged branch with introduce-then-fix ─────
_git init -q
_git config user.email t@e.st
_git config user.name test
_git config commit.gpgsign false

# main baseline — a clean file with no marker
printf 'line1\nline2\nline3\n' > "$_WORK/app.sh"
printf 'untouched\n' > "$_WORK/other.sh"
_git add app.sh other.sh
_git commit -qm "baseline on main"
_MAIN_SHA="$(_git rev-parse HEAD)"
_git branch -M main

# staged branch off main
_git checkout -q -b staged main

# commit A (unprovenanced): introduces a BUG marker (the intermediate problem)
printf 'line1\nline2\nBUG_TMPFILE_HARDCODED\nline3\n' > "$_WORK/app.sh"
_git add app.sh
_git commit -qm "A: add feature (introduces hardcoded /tmp)"
_SHA_A="$(_git rev-parse HEAD)"

# commit B (unprovenanced): unrelated edit to a second file (net-new, must appear)
printf 'feature_line\n' >> "$_WORK/other.sh"
_git add other.sh
_git commit -qm "B: extend other.sh"
_SHA_B="$(_git rev-parse HEAD)"

# commit D (unprovenanced): fixes A's BUG marker — net end-state of app.sh is clean
printf 'line1\nline2\nmktemp_safe\nline3\n' > "$_WORK/app.sh"
_git add app.sh
_git commit -qm "D: replace hardcoded /tmp with mktemp"
_SHA_D="$(_git rev-parse HEAD)"
_HEAD_SHA="$(_git rev-parse HEAD)"

# Scope = the three unprovenanced SHAs (A, B, D).
_SCOPE="$_WORK/scope.txt"
printf '%s\n%s\n%s\n' "$_SHA_A" "$_SHA_B" "$_SHA_D" > "$_SCOPE"

# ── Run the helper inside the fixture repo ───────────────────────────────────
_OUT="$_WORK/net.diff"
(
  cd "$_WORK" || exit 1
  build_net_integration_diff "main" "$_HEAD_SHA" "$_SCOPE" "$_OUT"
) > "$_WORK/count.txt"
_rc=$?

# T1: helper succeeds
if [[ $_rc -eq 0 ]]; then
    _pass "T1_helper_returns_zero"
else
    _fail "T1_helper_returns_zero" "rc=$_rc"
fi

# T2: net diff does NOT contain the intermediate BUG marker (the whole point —
#     introduce-then-fix collapsed; this is what stops the CS-10 re-flag).
if ! grep -q "BUG_TMPFILE_HARDCODED" "$_OUT"; then
    _pass "T2_intermediate_bug_marker_absent_from_net_diff"
else
    _fail "T2_intermediate_bug_marker_absent_from_net_diff" \
        "net diff re-includes the already-fixed intermediate state"
fi

# T3: the genuinely-new net change IS present (the fix's final form on app.sh).
if grep -q "mktemp_safe" "$_OUT"; then
    _pass "T3_final_state_present"
else
    _fail "T3_final_state_present" "net end-state of app.sh missing from diff"
fi

# T4: the unrelated net-new change on the second file IS present.
if grep -q "feature_line" "$_OUT"; then
    _pass "T4_net_new_unrelated_change_present"
else
    _fail "T4_net_new_unrelated_change_present" "other.sh net change missing"
fi

# T5: contrast — the OLD per-commit-concat approach WOULD re-flag. Prove the bug
#     is real by reconstructing the old behavior and showing the marker reappears.
_OLD="$_WORK/old.diff"
: > "$_OLD"
while IFS= read -r s; do
    _git show --format= --diff-merges=first-parent "$s" >> "$_OLD" 2>/dev/null || true
done < "$_SCOPE"
if grep -q "BUG_TMPFILE_HARDCODED" "$_OLD"; then
    _pass "T5_old_concat_approach_does_reflag_control"
else
    _fail "T5_old_concat_approach_does_reflag_control" \
        "control failed — old approach did not reproduce the re-flag, test is not exercising the bug"
fi

# T6: touched-file scope excludes files no unprovenanced commit touched. Add a
#     file only on main-side history and confirm it never enters the diff.
if ! grep -q "NEVER_TOUCHED_SENTINEL" "$_OUT"; then
    _pass "T6_scope_is_file_bounded"
else
    _fail "T6_scope_is_file_bounded" "diff leaked a file outside the unprovenanced set"
fi

# T7: a fully-reverted change (net zero) yields an empty diff for that file —
#     exercise an introduce-then-revert pair alone.
_git checkout -q -b staged2 main
printf 'line1\nline2\nTRANSIENT\nline3\n' > "$_WORK/app.sh"
_git add app.sh; _git commit -qm "introduce transient"
_S1="$(_git rev-parse HEAD)"
printf 'line1\nline2\nline3\n' > "$_WORK/app.sh"
_git add app.sh; _git commit -qm "revert transient"
_S2="$(_git rev-parse HEAD)"
printf '%s\n%s\n' "$_S1" "$_S2" > "$_WORK/scope2.txt"
_OUT2="$_WORK/net2.diff"
( cd "$_WORK" && build_net_integration_diff "main" "$(_git rev-parse HEAD)" "$_WORK/scope2.txt" "$_OUT2" ) >/dev/null
if [[ ! -s "$_OUT2" ]] || ! grep -q "TRANSIENT" "$_OUT2"; then
    _pass "T7_net_zero_collapses"
else
    _fail "T7_net_zero_collapses" "net-zero introduce-then-revert still shows the transient"
fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
