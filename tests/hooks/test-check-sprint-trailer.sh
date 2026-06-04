#!/usr/bin/env bash
# tests/hooks/test-check-sprint-trailer.sh
# Behavioral tests for plugins/dso/scripts/check-sprint-trailer.sh
#
# check-sprint-trailer.sh is a git pre-commit hook that enforces DSO-Story
# trailers on commits made during sprint mode.
#
# New interface (4-cell matrix): enforcement is gated on BOTH:
#   - dso.workflow=ci-pr  (read from WORKFLOW_CONFIG_FILE)
#   - .sprint-active file present at repo root
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

# make_workflow_config <dir> <dso_workflow_value>
# Creates a dso-config.conf in <dir> with the given dso.workflow value.
# Prints the path to the config file.
make_workflow_config() {
    local dir="$1"
    local workflow="$2"
    local conf="$dir/dso-config.conf"
    printf "dso.workflow=%s\n" "$workflow" > "$conf"
    printf "%s" "$conf"
}

# ---------------------------------------------------------------------------
# 4-cell dso.workflow matrix tests (RED — new interface not yet implemented)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# test_trailer_enforced_when_ci_pr_and_sprint_active
# dso.workflow=ci-pr + .sprint-active present + no DSO-Story trailer → exit 1
# RED: current hook ignores dso.workflow/.sprint-active; exits 0 (no DSO_SPRINT_MODE)
# ---------------------------------------------------------------------------
echo "--- test_trailer_enforced_when_ci_pr_and_sprint_active ---"
_conf_dir1=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir1")
_conf1=$(make_workflow_config "$_conf_dir1" "ci-pr")
_repo1=$(make_git_repo_with_commit "Add change without trailer")
touch "$_repo1/.sprint-active"
_exit1=0
_out1=$(
    cd "$_repo1" && \
    unset DSO_SPRINT_MODE && \
    WORKFLOW_CONFIG_FILE="$_conf1" bash "$TARGET_SCRIPT" 2>&1
) || _exit1=$?
assert_ne "ci-pr+sprint-active, no trailer: exit non-zero" "0" "$_exit1"
assert_contains "ci-pr+sprint-active, no trailer: stderr mentions DSO-Story" "DSO-Story" "$_out1"

# ---------------------------------------------------------------------------
# test_trailer_nonenforced_when_ci_pr_no_sprint_active
# dso.workflow=ci-pr + no .sprint-active + no DSO-Story trailer → exit 0
# RED: current hook uses DSO_SPRINT_MODE=1 which would enforce; new interface
#      must ignore DSO_SPRINT_MODE and use .sprint-active instead.
# ---------------------------------------------------------------------------
echo "--- test_trailer_nonenforced_when_ci_pr_no_sprint_active ---"
_conf_dir2=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir2")
_conf2=$(make_workflow_config "$_conf_dir2" "ci-pr")
_repo2=$(make_git_repo_with_commit "Add change without trailer")
# no .sprint-active file
_exit2=0
(
    cd "$_repo2" && \
    DSO_SPRINT_MODE=1 \
    WORKFLOW_CONFIG_FILE="$_conf2" bash "$TARGET_SCRIPT"
) 2>/dev/null || _exit2=$?
assert_eq "ci-pr, no sprint-active: exit 0 (DSO_SPRINT_MODE ignored)" "0" "$_exit2"

# ---------------------------------------------------------------------------
# test_trailer_nonenforced_when_local_with_sprint_active
# dso.workflow=local + .sprint-active present + no DSO-Story trailer → exit 0
# RED: current hook uses DSO_SPRINT_MODE=1 which would enforce; new interface
#      must not enforce when dso.workflow=local regardless of .sprint-active.
# ---------------------------------------------------------------------------
echo "--- test_trailer_nonenforced_when_local_with_sprint_active ---"
_conf_dir3=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir3")
_conf3=$(make_workflow_config "$_conf_dir3" "local")
_repo3=$(make_git_repo_with_commit "Add change without trailer")
touch "$_repo3/.sprint-active"
_exit3=0
(
    cd "$_repo3" && \
    DSO_SPRINT_MODE=1 \
    WORKFLOW_CONFIG_FILE="$_conf3" bash "$TARGET_SCRIPT"
) 2>/dev/null || _exit3=$?
assert_eq "local+sprint-active: exit 0 (workflow=local never enforces)" "0" "$_exit3"

# ---------------------------------------------------------------------------
# test_trailer_nonenforced_when_local_no_sprint_active
# dso.workflow=local + no .sprint-active + no DSO-Story trailer → exit 0
# RED: current hook uses DSO_SPRINT_MODE=1 which would enforce; new interface
#      must not enforce when dso.workflow=local.
# ---------------------------------------------------------------------------
echo "--- test_trailer_nonenforced_when_local_no_sprint_active ---"
_conf_dir4=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir4")
_conf4=$(make_workflow_config "$_conf_dir4" "local")
_repo4=$(make_git_repo_with_commit "Add change without trailer")
# no .sprint-active file
_exit4=0
(
    cd "$_repo4" && \
    DSO_SPRINT_MODE=1 \
    WORKFLOW_CONFIG_FILE="$_conf4" bash "$TARGET_SCRIPT"
) 2>/dev/null || _exit4=$?
assert_eq "local, no sprint-active: exit 0 (workflow=local never enforces)" "0" "$_exit4"

# ---------------------------------------------------------------------------
# test_trailer_passes_when_ci_pr_sprint_active_with_dso_story
# dso.workflow=ci-pr + .sprint-active + valid DSO-Story trailer → exit 0
# Verifies the enforcement gate passes when the trailer is present.
# ---------------------------------------------------------------------------
echo "--- test_trailer_passes_when_ci_pr_sprint_active_with_dso_story ---"
_conf_dir5=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir5")
_conf5=$(make_workflow_config "$_conf_dir5" "ci-pr")
_repo5=$(make_git_repo_with_commit "Add change

DSO-Story: My story title")
touch "$_repo5/.sprint-active"
_exit5=0
(
    cd "$_repo5" && \
    unset DSO_SPRINT_MODE && \
    WORKFLOW_CONFIG_FILE="$_conf5" bash "$TARGET_SCRIPT"
) 2>/dev/null || _exit5=$?
assert_eq "ci-pr+sprint-active+trailer: exit 0 (trailer satisfies gate)" "0" "$_exit5"

# ---------------------------------------------------------------------------
# test_trailer_read_from_msg_file_arg_not_head (aba6-56fa)
# When invoked at commit-msg stage, pre-commit passes the message file as $1.
# HEAD has NO trailer; the message file passed as $1 HAS a trailer.
# The script must inspect $1 (the in-progress commit being made), not HEAD.
# ---------------------------------------------------------------------------
echo "--- test_trailer_read_from_msg_file_arg_not_head ---"
_conf_dir6=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir6")
_conf6=$(make_workflow_config "$_conf_dir6" "ci-pr")
# HEAD commit has NO trailer
_repo6=$(make_git_repo_with_commit "Previous commit without trailer")
touch "$_repo6/.sprint-active"
# Build a message file with a valid trailer
_msg_file6=$(mktemp)
_TEMP_DIRS+=("$_msg_file6")
printf 'fix: new commit\n\nDSO-Story: aba6-56fa-0000-0000\n' > "$_msg_file6"
_exit6=0
(
    cd "$_repo6" && \
    unset DSO_SPRINT_MODE && \
    WORKFLOW_CONFIG_FILE="$_conf6" bash "$TARGET_SCRIPT" "$_msg_file6"
) 2>/dev/null || _exit6=$?
assert_eq "ci-pr+sprint-active: trailer in \$1 file satisfies gate even when HEAD lacks one" "0" "$_exit6"

# Negative: HEAD has a properly-formatted trailer (subject + blank line +
# trailer line, so `git interpret-trailers --parse` returns non-empty), but
# the IN-PROGRESS commit (via $1) lacks one → must reject. This proves the
# script consults $1, not HEAD.
#
# PR #180 review finding: the prior fixture used "Previous commit\nwith
# DSO-Story: previous-story-0000" — no blank-line separator. `git
# interpret-trailers` returns empty for that input, so the prior test
# couldn't distinguish "script correctly read $1" from "script regressed
# to reading HEAD and HEAD happened to lack a trailer." The new fixture
# uses the canonical "<subject>\n\n<trailer>" form so the script's
# behavior under regression would observably differ.
echo "--- test_trailer_rejects_when_msg_file_has_no_trailer_even_if_head_does ---"
_repo7=$(make_git_repo_with_commit "Previous commit subject

DSO-Story: previous-story-0000")
touch "$_repo7/.sprint-active"
_msg_file7=$(mktemp)
_TEMP_DIRS+=("$_msg_file7")
printf 'fix: missing-trailer commit\n' > "$_msg_file7"
_exit7=0
(
    cd "$_repo7" && \
    unset DSO_SPRINT_MODE && \
    WORKFLOW_CONFIG_FILE="$_conf6" bash "$TARGET_SCRIPT" "$_msg_file7"
) 2>/dev/null || _exit7=$?
assert_ne "ci-pr+sprint-active: \$1 lacks trailer must reject (HEAD trailer ignored)" "0" "$_exit7"

# ---------------------------------------------------------------------------
# test_trailer_enforced_when_dso_sprint_trailer_required_no_sprint_active_no_trailer
# DSO_SPRINT_TRAILER_REQUIRED=1 + dso.workflow=ci-pr + no .sprint-active
# + no DSO-Story trailer → exit 1
# RED: current hook only checks .sprint-active; env var alone does not trigger
#      enforcement. After fix (OR-condition in check-sprint-trailer.sh), this
#      must exit nonzero.
# ---------------------------------------------------------------------------
echo "--- test_trailer_enforced_when_dso_sprint_trailer_required_no_sprint_active_no_trailer ---"
_conf_dir8=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir8")
_conf8=$(make_workflow_config "$_conf_dir8" "ci-pr")
_repo8=$(make_git_repo_with_commit "fix: task commit without trailer")
# Explicitly NO .sprint-active file (ensures env var is the only trigger)
rm -f "$_repo8/.sprint-active"
_exit8=0
_out8=$(
    cd "$_repo8" && \
    DSO_SPRINT_TRAILER_REQUIRED=1 \
    WORKFLOW_CONFIG_FILE="$_conf8" bash "$TARGET_SCRIPT" 2>&1
) || _exit8=$?
assert_ne "DSO_SPRINT_TRAILER_REQUIRED=1, no .sprint-active, no trailer: exit non-zero" "0" "$_exit8"
assert_contains "DSO_SPRINT_TRAILER_REQUIRED=1, no .sprint-active, no trailer: stderr mentions DSO-Story" "DSO-Story" "$_out8"

# ---------------------------------------------------------------------------
# test_trailer_passes_when_dso_sprint_trailer_required_no_sprint_active_with_trailer
# DSO_SPRINT_TRAILER_REQUIRED=1 + dso.workflow=ci-pr + no .sprint-active
# + valid DSO-Story trailer → exit 0
# RED: same — env var not yet recognized. After fix, must exit 0.
# ---------------------------------------------------------------------------
echo "--- test_trailer_passes_when_dso_sprint_trailer_required_no_sprint_active_with_trailer ---"
_conf_dir9=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir9")
_conf9=$(make_workflow_config "$_conf_dir9" "ci-pr")
_repo9=$(make_git_repo_with_commit "fix: task commit

DSO-Story: test-story-0001")
# Explicitly NO .sprint-active file
rm -f "$_repo9/.sprint-active"
_exit9=0
(
    cd "$_repo9" && \
    DSO_SPRINT_TRAILER_REQUIRED=1 \
    WORKFLOW_CONFIG_FILE="$_conf9" bash "$TARGET_SCRIPT"
) 2>/dev/null || _exit9=$?
assert_eq "DSO_SPRINT_TRAILER_REQUIRED=1, no .sprint-active, with trailer: exit 0" "0" "$_exit9"

# ---------------------------------------------------------------------------
# Regression: existing cells still work with DSO_SPRINT_TRAILER_REQUIRED absent
# ---------------------------------------------------------------------------
# Regression A: ci-pr + .sprint-active + no trailer → exit 1 (unchanged)
echo "--- regression: ci-pr+sprint-active, no trailer, no env var → still rejected ---"
_conf_dir10=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir10")
_conf10=$(make_workflow_config "$_conf_dir10" "ci-pr")
_repo10=$(make_git_repo_with_commit "fix: missing trailer")
touch "$_repo10/.sprint-active"
_exit10=0
_out10=$(
    cd "$_repo10" && \
    unset DSO_SPRINT_TRAILER_REQUIRED 2>/dev/null; \
    unset DSO_SPRINT_MODE 2>/dev/null; \
    WORKFLOW_CONFIG_FILE="$_conf10" bash "$TARGET_SCRIPT" 2>&1
) || _exit10=$?
assert_ne "regression A: ci-pr+sprint-active, no trailer, no env var: still exit non-zero" "0" "$_exit10"

# Regression B: local + .sprint-active + DSO_SPRINT_TRAILER_REQUIRED=1 + no trailer → exit 0
# (dso.workflow=local means never enforce regardless of env var)
echo "--- regression: local+sprint-active+DSO_SPRINT_TRAILER_REQUIRED=1, no trailer → still exit 0 ---"
_conf_dir11=$(mktemp -d)
_TEMP_DIRS+=("$_conf_dir11")
_conf11=$(make_workflow_config "$_conf_dir11" "local")
_repo11=$(make_git_repo_with_commit "fix: missing trailer")
touch "$_repo11/.sprint-active"
_exit11=0
(
    cd "$_repo11" && \
    DSO_SPRINT_TRAILER_REQUIRED=1 \
    WORKFLOW_CONFIG_FILE="$_conf11" bash "$TARGET_SCRIPT"
) 2>/dev/null || _exit11=$?
assert_eq "regression B: local+sprint-active+env-var, no trailer: still exit 0 (workflow=local never enforces)" "0" "$_exit11"

print_summary
