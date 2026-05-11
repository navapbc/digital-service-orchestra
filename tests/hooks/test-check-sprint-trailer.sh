#!/usr/bin/env bash
# tests/hooks/test-check-sprint-trailer.sh
# Behavioral tests for plugins/dso/scripts/check-sprint-trailer.sh
#
# check-sprint-trailer.sh is a git pre-commit hook that enforces DSO-Story
# trailers on commits made during sprint mode (DSO_SPRINT_MODE=1).
#
# Observable surfaces tested:
#   - exit code (0 = pass, non-zero = reject)
#   - stderr content (must mention "DSO-Story" when rejecting)
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

TARGET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/check-sprint-trailer.sh"

# RED gate: fail immediately if target script is absent
if [[ ! -f "$TARGET_SCRIPT" ]]; then
    printf "FAIL: check-sprint-trailer.sh does not exist at: %s\n" "$TARGET_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

# ---------------------------------------------------------------------------
# Isolation helpers
# ---------------------------------------------------------------------------
_TEMP_DIRS=()
cleanup_all() {
    local d
    for d in "${_TEMP_DIRS[@]+"${_TEMP_DIRS[@]}"}"; do
        rm -rf "$d"
    done
}
trap cleanup_all EXIT

# make_git_repo_with_commit <commit_message>
# Creates a minimal git repo with a single commit, prints the repo path.
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

# ---------------------------------------------------------------------------
# test_sprint_mode_trailer_absent_rejected
# When DSO_SPRINT_MODE=1 and the latest commit lacks a DSO-Story trailer,
# the hook must exit non-zero and emit "DSO-Story" to stderr.
# ---------------------------------------------------------------------------
echo "--- test_sprint_mode_trailer_absent_rejected ---"
_repo1=$(make_git_repo_with_commit "Add some change

No trailer here.")
_exit1=0
_out1=$(
    cd "$_repo1" && DSO_SPRINT_MODE=1 bash "$TARGET_SCRIPT" 2>&1
) || _exit1=$?
assert_ne "sprint mode, no trailer: exit non-zero" "0" "$_exit1"
assert_contains "sprint mode, no trailer: stderr mentions DSO-Story" "DSO-Story" "$_out1"

# ---------------------------------------------------------------------------
# test_sprint_mode_trailer_present_passes
# When DSO_SPRINT_MODE=1 and the commit contains a DSO-Story: trailer,
# the hook must exit 0.
# ---------------------------------------------------------------------------
echo "--- test_sprint_mode_trailer_present_passes ---"
_repo2=$(make_git_repo_with_commit "Add some change

DSO-Story: My story title")
_exit2=0
(
    cd "$_repo2" && DSO_SPRINT_MODE=1 bash "$TARGET_SCRIPT"
) 2>/dev/null || _exit2=$?
assert_eq "sprint mode, trailer present: exit 0" "0" "$_exit2"

# ---------------------------------------------------------------------------
# test_non_sprint_mode_passthrough
# When DSO_SPRINT_MODE is unset, the hook must exit 0 regardless of
# whether a DSO-Story trailer is present.
# ---------------------------------------------------------------------------
echo "--- test_non_sprint_mode_passthrough ---"
_repo3=$(make_git_repo_with_commit "Add some change without trailer")
_exit3=0
(
    cd "$_repo3" && unset DSO_SPRINT_MODE && bash "$TARGET_SCRIPT"
) 2>/dev/null || _exit3=$?
assert_eq "non-sprint mode: exit 0" "0" "$_exit3"

print_summary
