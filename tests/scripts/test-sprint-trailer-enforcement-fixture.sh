#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2030,SC2031  # cd/subshell patterns in test setup
# tests/scripts/test-sprint-trailer-enforcement-fixture.sh
# F5 of bug db71-e078-ec99-4fbf: fixture-driven verification of
# verify-story-merge-trailer.sh against the f360-3a5b cross-contamination
# pattern.
#
# Scenarios:
#   1. Run fixture setup → confirm 3 fake-story IDs have NO trailers.
#   2. Run verify-story-merge-trailer.sh fake-story-1 against fixture → exit 1.
#   3. Add an --allow-empty trailer commit for fake-story-1.
#   4. Re-run verify-story-merge-trailer.sh fake-story-1 → exit 0.
#   5. Clean up the fixture working directory.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP="$REPO_ROOT/tests/fixtures/sprint-trailer-enforcement/setup.sh"
VERIFY="$REPO_ROOT/plugins/dso/scripts/verify-story-merge-trailer.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-trailer-enforcement-fixture.sh ==="

if [[ ! -x "$SETUP" ]] || [[ ! -x "$VERIFY" ]]; then
    echo "FAIL: required scripts missing or not executable" >&2
    (( ++FAIL ))
    print_summary
fi

# Build the fixture.
FIXTURE=$(bash "$SETUP")

if [[ ! -d "$FIXTURE/.git" ]]; then
    echo "FAIL: setup.sh did not produce a git repo at: $FIXTURE" >&2
    (( ++FAIL ))
    print_summary
fi

# --- Scenario 1+2: trailer absent → exit 1 ---
_snapshot_fail
_RC=0
_STDERR=$(mktemp "${TMPDIR:-/tmp}/test-fixture-stderr.XXXXXX")
(
    cd "$FIXTURE" || return
    bash "$VERIFY" "fake-story-1" --base=base-ref 2>"$_STDERR"
) || _RC=$?
assert_ne "fixture_verify_exits_nonzero_when_absent" "0" "$_RC"
_STDERR_CONTENT=$(cat "$_STDERR")
assert_contains \
    "fixture_verify_stderr_mentions_trailer" \
    "DSO-Story-Merge" \
    "$_STDERR_CONTENT"
rm -f "$_STDERR"
assert_pass_if_clean "fixture_no_trailer_blocks_close"

# --- Scenario 3+4: add empty trailer commit → exit 0 ---
_snapshot_fail
(
    cd "$FIXTURE" || return
    git commit --allow-empty -m "Merge story/recovery/fake-story-1

DSO-Story-Merge: fake-story-1" --quiet
)
_RC2=0
(
    cd "$FIXTURE" || return
    bash "$VERIFY" "fake-story-1" --base=base-ref >/dev/null 2>&1
) || _RC2=$?
assert_eq "fixture_verify_exits_zero_after_recovery_commit" "0" "$_RC2"
assert_pass_if_clean "fixture_recovery_commit_unblocks_close"

# --- Scenario 5: cleanup ---
rm -rf "$FIXTURE"
_snapshot_fail
if [[ ! -d "$FIXTURE" ]]; then (( ++PASS )); else (( ++FAIL )); fi
assert_pass_if_clean "fixture_cleanup_succeeded"

print_summary
