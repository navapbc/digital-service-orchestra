#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2030,SC2031
# tests/scripts/test-verify-story-merge-trailer.sh
# Behavioral tests for plugins/dso/scripts/verify-story-merge-trailer.sh
#
# TDD: RED before the script exists. Bug db71-e078-ec99-4fbf.
#
# Scenarios:
#   T1 — trailer present on a commit in <base>..HEAD → exit 0
#   T2 — trailer absent on every commit in <base>..HEAD → exit 1 + stderr
#   T3 — wrong-story-id trailer does NOT match → exit 1
#   T4 — missing arg → exit non-zero
#   T5 — --help flag → exit 0 with usage text on stdout
#   T6 — empty-commit (--allow-empty) carrying the trailer counts → exit 0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY_SCRIPT="$REPO_ROOT/plugins/dso/scripts/verify-story-merge-trailer.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-verify-story-merge-trailer.sh ==="

if [[ ! -f "$VERIFY_SCRIPT" ]]; then
    echo "FAIL: script not found: $VERIFY_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

_setup_repo_with_base() {
    _TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-verify-story-trailer.XXXXXX")
    git init "$_TEST_DIR" --initial-branch=main --quiet 2>/dev/null \
        || git init "$_TEST_DIR" --quiet 2>/dev/null
    (
        cd "$_TEST_DIR" || return
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -m "initial" --quiet
        # tag the base ref so we can reference it predictably
        git branch base-ref HEAD --quiet 2>/dev/null || git update-ref refs/heads/base-ref HEAD
    )
}

# --- T1: trailer present in range ---
echo ""
echo "--- T1: trailer_present_in_range_exits_zero ---"
_snapshot_fail
_setup_repo_with_base
(
    cd "$_TEST_DIR" || return
    echo "work" > work.txt
    git add work.txt
    git commit -m "story work

DSO-Story-Merge: story-aaaa" --quiet
)
_T1_RC=0
(
    cd "$_TEST_DIR" || return
    bash "$VERIFY_SCRIPT" "story-aaaa" --base=base-ref >/dev/null 2>&1
) || _T1_RC=$?
assert_eq "T1_exit_zero_when_trailer_present" "0" "$_T1_RC"
assert_pass_if_clean "T1_trailer_present_in_range_exits_zero"
rm -rf "$_TEST_DIR"

# --- T2: trailer absent ---
echo ""
echo "--- T2: trailer_absent_exits_nonzero_with_stderr ---"
_snapshot_fail
_setup_repo_with_base
(
    cd "$_TEST_DIR" || return
    echo "x" > x.txt
    git add x.txt
    git commit -m "no trailer here" --quiet
)
_T2_STDERR=$(mktemp "${TMPDIR:-/tmp}/test-verify-t2-stderr.XXXXXX")
_T2_RC=0
(
    cd "$_TEST_DIR" || return
    bash "$VERIFY_SCRIPT" "story-bbbb" --base=base-ref 2>"$_T2_STDERR"
) || _T2_RC=$?
assert_ne "T2_exit_nonzero_when_absent" "0" "$_T2_RC"
_T2_STDERR_CONTENT=$(cat "$_T2_STDERR")
assert_ne "T2_stderr_nonempty" "" "$_T2_STDERR_CONTENT"
rm -f "$_T2_STDERR"
assert_pass_if_clean "T2_trailer_absent_exits_nonzero_with_stderr"
rm -rf "$_TEST_DIR"

# --- T3: wrong-id trailer does not match ---
echo ""
echo "--- T3: wrong_story_id_trailer_does_not_match ---"
_snapshot_fail
_setup_repo_with_base
(
    cd "$_TEST_DIR" || return
    echo "y" > y.txt
    git add y.txt
    git commit -m "other story

DSO-Story-Merge: story-other" --quiet
)
_T3_RC=0
(
    cd "$_TEST_DIR" || return
    bash "$VERIFY_SCRIPT" "story-target" --base=base-ref >/dev/null 2>&1
) || _T3_RC=$?
assert_ne "T3_exit_nonzero_for_wrong_id" "0" "$_T3_RC"
assert_pass_if_clean "T3_wrong_story_id_trailer_does_not_match"
rm -rf "$_TEST_DIR"

# --- T4: missing arg ---
echo ""
echo "--- T4: missing_arg_exits_nonzero ---"
_snapshot_fail
_T4_RC=0
bash "$VERIFY_SCRIPT" >/dev/null 2>&1 || _T4_RC=$?
assert_ne "T4_missing_arg_exits_nonzero" "0" "$_T4_RC"
assert_pass_if_clean "T4_missing_arg_exits_nonzero"

# --- T5: --help ---
echo ""
echo "--- T5: help_flag_prints_usage ---"
_snapshot_fail
_T5_OUT=$(bash "$VERIFY_SCRIPT" --help 2>&1) || true
_T5_RC=0
bash "$VERIFY_SCRIPT" --help >/dev/null 2>&1 || _T5_RC=$?
assert_eq "T5_help_exit_zero" "0" "$_T5_RC"
assert_contains "T5_help_mentions_usage" "Usage" "$_T5_OUT"
assert_pass_if_clean "T5_help_flag_prints_usage"

# --- T6: empty commit carrying trailer counts ---
echo ""
echo "--- T6: empty_commit_with_trailer_counts ---"
_snapshot_fail
_setup_repo_with_base
(
    cd "$_TEST_DIR" || return
    git commit --allow-empty -m "Merge story branch (no-diff)

DSO-Story-Merge: story-empty" --quiet
)
_T6_RC=0
(
    cd "$_TEST_DIR" || return
    bash "$VERIFY_SCRIPT" "story-empty" --base=base-ref >/dev/null 2>&1
) || _T6_RC=$?
assert_eq "T6_exit_zero_for_empty_commit_with_trailer" "0" "$_T6_RC"
assert_pass_if_clean "T6_empty_commit_with_trailer_counts"
rm -rf "$_TEST_DIR"

print_summary
