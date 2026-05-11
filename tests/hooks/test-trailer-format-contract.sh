#!/usr/bin/env bash
# tests/hooks/test-trailer-format-contract.sh
# Format contract test: emitter (apply-attribution-trailers.sh) produces a
# DSO-Story trailer that validator (check-sprint-trailer.sh) accepts.
#
# Uses a fixture commit message (not a live call to apply-attribution-trailers.sh,
# which requires real ticket context) to lock the exact format both sides must agree on.
#
# Canonical format (per apply-attribution-trailers.sh line 320):
#   DSO-Story: <parent_story_title>
# git interpret-trailers convention: key + ': ' + value (single space after colon)
set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

CHECK_SCRIPT="$REPO_ROOT/plugins/dso/scripts/check-sprint-trailer.sh"

# RED gate: fail if check-sprint-trailer.sh is absent
if [[ ! -f "$CHECK_SCRIPT" ]]; then
    printf "FAIL: check-sprint-trailer.sh does not exist at: %s\n" "$CHECK_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

_TEMP_DIRS=()
cleanup_all() { for d in "${_TEMP_DIRS[@]+"${_TEMP_DIRS[@]}"}"; do rm -rf "$d"; done }
trap cleanup_all EXIT

make_git_repo_with_commit() {
    local msg="$1"
    local dir
    dir=$(mktemp -d)
    _TEMP_DIRS+=("$dir")
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    printf "content\n" > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "$msg"
    printf "%s" "$dir"
}

# Fixture: the canonical trailer format emitted by apply-attribution-trailers.sh
# Format: 'DSO-Story: <title>' — note single space after colon (git interpret-trailers convention)
FIXTURE_TITLE="Per-Story PR Review Structure with Incremental Attestation"
FIXTURE_COMMIT_MSG="feat: implement feature

DSO-Story: ${FIXTURE_TITLE}"

# Case 1: fixture trailer format is accepted by validator (exit 0)
echo "--- test_fixture_trailer_format_accepted ---"
_repo1=$(make_git_repo_with_commit "$FIXTURE_COMMIT_MSG")
_exit1=0
(cd "$_repo1" && DSO_SPRINT_MODE=1 bash "$CHECK_SCRIPT") 2>/dev/null || _exit1=$?
assert_eq "fixture trailer format: accepted by validator" "0" "$_exit1"

# Case 2: commit without trailer is rejected in sprint mode
echo "--- test_no_trailer_rejected ---"
_repo2=$(make_git_repo_with_commit "feat: implement feature without trailer")
_exit2=0
_out2=$(cd "$_repo2" && DSO_SPRINT_MODE=1 bash "$CHECK_SCRIPT" 2>&1) || _exit2=$?
assert_ne "no trailer: exit non-zero" "0" "$_exit2"
assert_contains "no trailer: error mentions DSO-Story" "DSO-Story" "$_out2"

print_summary
