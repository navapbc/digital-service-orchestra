#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2030,SC2031  # cd/subshell patterns in test setup
# tests/scripts/test-merge-squash-rebase.sh
# Tests for _squash_rebase_recovery() function in merge-to-main.sh
#
# TDD tests:
#   1. test_noop_when_single_commit
#   2. test_squash_reduces_commits_to_one
#   3. test_rebase_onto_diverged_main
#   4. test_force_push_warning_when_branch_on_origin
#   5. test_force_push_failure_restores_pre_squash_head
#   6. test_auto_resolves_tickets_index_via_merge_driver
#   7. test_prints_file_list_on_unresolvable_conflict
#
# Each test creates an isolated temp git repo with a local "origin" remote.
# Sets BRANCH, GIT_ATTR_NOSYSTEM=1, and unsets the custom merge driver.
#
# Usage: bash tests/scripts/test-merge-squash-rebase.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"
source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-squash-rebase.sh ==="

# =============================================================================
# Helper: extract a named function from merge-to-main.sh
# =============================================================================
_extract_fn() {
    local fn_name="$1"
    local _body
    _body=$(awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_SCRIPT")
    if [[ -z "$_body" ]] && [[ -f "${MERGE_HELPERS_LIB:-}" ]]; then
        _body=$(awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_HELPERS_LIB")
    fi
    echo "$_body"
}

# =============================================================================
# Helper: set up an isolated git repo pair (bare origin + working clone)
# Sets globals: _TEST_BASE, _ORIGIN_DIR, _WORK_DIR
# Usage: _setup_git_pair [branch_name]
#   branch_name — name for the feature branch (default: feature-test-branch)
# =============================================================================
_setup_git_pair() {
    local branch_name="${1:-feature-test-branch}"

    _TEST_BASE=$(mktemp -d)
    _ORIGIN_DIR="$_TEST_BASE/origin.git"
    _WORK_DIR="$_TEST_BASE/work"

    # Disable system gitattributes and unset the merge driver
    export GIT_ATTR_NOSYSTEM=1

    git init --bare "$_ORIGIN_DIR" -b main --quiet 2>/dev/null
    git clone "$_ORIGIN_DIR" "$_WORK_DIR" --quiet 2>/dev/null
    (
        cd "$_WORK_DIR"
        git config user.email "test@test.com"
        git config user.name "Test"
        # Unset custom merge driver so tests are not affected by local git config
        echo "init" > README.md
        git add README.md
        git commit -m "initial commit" --quiet
        git push origin main --quiet 2>/dev/null

        # Create and switch to feature branch
        git checkout -b "$branch_name" --quiet
    )
}

# Load the recovery function under test from the script.
# Exports CLAUDE_PLUGIN_ROOT so the function resolves paths correctly
# when eval'd outside the normal merge-to-main.sh execution context.
_load_recovery_fn() {
    export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
    eval "$(_extract_fn "_squash_rebase_recovery")"
}

# =============================================================================
# Test 1: test_noop_when_single_commit
# If HEAD is only 1 commit ahead of origin/main (commit count <=1),
# the squash step should be skipped and rebase should still succeed.
# =============================================================================
echo ""
echo "--- test_noop_when_single_commit ---"
_snapshot_fail

_setup_git_pair "test-single"
(
    cd "$_WORK_DIR"
    git config user.email "test@test.com"
    git config user.name "Test"
    # Add exactly one commit on the feature branch
    echo "one feature commit" > feature.txt
    git add feature.txt
    git commit -m "single feature commit" --quiet
)

_T1_RC=0
_T1_OUTPUT=$(
    cd "$_WORK_DIR"
    export BRANCH="test-single"
    export GIT_ATTR_NOSYSTEM=1
    _load_recovery_fn
    _squash_rebase_recovery 2>&1
) || _T1_RC=$?

assert_eq "test_noop_when_single_commit_exits_0" "0" "$_T1_RC"

assert_pass_if_clean "test_noop_when_single_commit"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 2: test_squash_reduces_commits_to_one
# With 3 commits on the branch, squash should reduce them to 1 commit.
# After recovery, HEAD should be 1 commit ahead of origin/main.
# =============================================================================
echo ""
echo "--- test_squash_reduces_commits_to_one ---"
_snapshot_fail

_setup_git_pair "test-squash"
(
    cd "$_WORK_DIR"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "commit 1" > file1.txt; git add file1.txt; git commit -m "commit 1" --quiet
    echo "commit 2" > file2.txt; git add file2.txt; git commit -m "commit 2" --quiet
    echo "commit 3" > file3.txt; git add file3.txt; git commit -m "commit 3" --quiet
)

_T2_RC=0
_T2_OUTPUT=$(
    cd "$_WORK_DIR"
    export BRANCH="test-squash"
    export GIT_ATTR_NOSYSTEM=1
    _load_recovery_fn
    _squash_rebase_recovery 2>&1
) || _T2_RC=$?

# Function should succeed
assert_eq "test_squash_reduces_commits_exits_0" "0" "$_T2_RC"

# After squash, there should be exactly 1 commit ahead of origin/main
_T2_COMMIT_COUNT=$(cd "$_WORK_DIR" && git rev-list --count origin/main..HEAD 2>/dev/null || echo "error")
assert_eq "test_squash_reduces_commits_to_one_count" "1" "$_T2_COMMIT_COUNT"

assert_pass_if_clean "test_squash_reduces_commits_to_one"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 3: test_rebase_onto_diverged_main
# Add commits to origin/main (simulating other merged work), then run
# recovery on the branch. The branch should rebase cleanly onto diverged main.
# =============================================================================
echo ""
echo "--- test_rebase_onto_diverged_main ---"
_snapshot_fail

_setup_git_pair "test-rebase"
(
    cd "$_WORK_DIR"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "branch work" > branch.txt
    git add branch.txt
    git commit -m "branch commit 1" --quiet
    echo "more branch work" >> branch.txt
    git add branch.txt
    git commit -m "branch commit 2" --quiet
)

# Push a diverging commit to origin/main from a second clone
_WORK2="$_TEST_BASE/work2"
git clone "$_ORIGIN_DIR" "$_WORK2" --quiet 2>/dev/null
(
    cd "$_WORK2"
    git config user.email "test2@test.com"
    git config user.name "Test2"
    echo "main diverge" > main_only.txt
    git add main_only.txt
    git commit -m "main diverging commit" --quiet
    git push origin main --quiet 2>/dev/null
)

_T3_RC=0
_T3_OUTPUT=$(
    cd "$_WORK_DIR"
    export BRANCH="test-rebase"
    export GIT_ATTR_NOSYSTEM=1
    _load_recovery_fn
    _squash_rebase_recovery 2>&1
) || _T3_RC=$?

assert_eq "test_rebase_onto_diverged_main_exits_0" "0" "$_T3_RC"

# Verify the squashed commit is on top of the diverged origin/main
_T3_MERGE_BASE=$(cd "$_WORK_DIR" && git merge-base HEAD origin/main 2>/dev/null || echo "")
_T3_ORIGIN_MAIN=$(cd "$_WORK_DIR" && git rev-parse origin/main 2>/dev/null || echo "")
assert_eq "test_rebase_ontop_of_origin_main" "$_T3_ORIGIN_MAIN" "$_T3_MERGE_BASE"

assert_pass_if_clean "test_rebase_onto_diverged_main"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 4: test_force_push_warning_when_branch_on_origin
# When the branch exists on origin, recovery should attempt a force-with-lease push.
# Verify the output contains an indication of force-push (or that it succeeds).
# =============================================================================
echo ""
echo "--- test_force_push_warning_when_branch_on_origin ---"
_snapshot_fail

_setup_git_pair "test-fpush"
(
    cd "$_WORK_DIR"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "commit a" > a.txt; git add a.txt; git commit -m "commit a" --quiet
    echo "commit b" > b.txt; git add b.txt; git commit -m "commit b" --quiet
    # Push the branch to origin so it exists there
    git push origin test-fpush --quiet 2>/dev/null
)

_T4_RC=0
_T4_OUTPUT=$(
    cd "$_WORK_DIR"
    export BRANCH="test-fpush"
    export GIT_ATTR_NOSYSTEM=1
    _load_recovery_fn
    _squash_rebase_recovery 2>&1
) || _T4_RC=$?

# Should succeed overall (squash + force-push + rebase)
assert_eq "test_force_push_branch_on_origin_exits_0" "0" "$_T4_RC"

# Output should contain RECOVERY success or force-with-lease indication
_T4_HAS_RECOVERY=0
if [[ "${_T4_OUTPUT,,}" =~ force-with-lease|recovery.*squash|squash.*succeeded|recovery ]]; then
    _T4_HAS_RECOVERY=1
fi
assert_eq "test_force_push_output_indicates_push_or_success" "1" "$_T4_HAS_RECOVERY"

assert_pass_if_clean "test_force_push_warning_when_branch_on_origin"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 5: test_force_push_failure_restores_pre_squash_head
# Simulate a force-push failure by making push impossible (readonly remote).
# The HEAD should be restored to its pre-squash value.
# =============================================================================
echo ""
echo "--- test_force_push_failure_restores_pre_squash_head ---"
_snapshot_fail

_setup_git_pair "test-restore"
(
    cd "$_WORK_DIR"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "commit x" > x.txt; git add x.txt; git commit -m "commit x" --quiet
    echo "commit y" > y.txt; git add y.txt; git commit -m "commit y" --quiet
    # Push branch to origin so force-push will be attempted
    git push origin test-restore --quiet 2>/dev/null
)

# Record the pre-squash HEAD (2 commits ahead of origin/main)
_T5_PRE_HEAD=$(cd "$_WORK_DIR" && git rev-parse HEAD)

# Make the origin bare repo read-only so force-push fails
chmod -R a-w "$_ORIGIN_DIR" 2>/dev/null || true

_T5_RC=0
_T5_OUTPUT=$(
    cd "$_WORK_DIR"
    export BRANCH="test-restore"
    export GIT_ATTR_NOSYSTEM=1
    _load_recovery_fn
    _squash_rebase_recovery 2>&1
) || _T5_RC=$?

# Restore permissions so cleanup can proceed
chmod -R u+w "$_ORIGIN_DIR" 2>/dev/null || true

# Recovery should fail (return 1) when force-push fails
assert_eq "test_force_push_failure_returns_1" "1" "$_T5_RC"

# HEAD should be restored to pre-squash state
_T5_POST_HEAD=$(cd "$_WORK_DIR" && git rev-parse HEAD 2>/dev/null || echo "error")
assert_eq "test_force_push_failure_restores_head" "$_T5_PRE_HEAD" "$_T5_POST_HEAD"

assert_pass_if_clean "test_force_push_failure_restores_pre_squash_head"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 6: test_prints_file_list_on_unresolvable_conflict
# Create a conflict in a non-.tickets-tracker/.index.json file. The function should
# print "ACTION REQUIRED" with the conflicted file list and return 1.
# =============================================================================
echo ""
echo "--- test_prints_file_list_on_unresolvable_conflict ---"
_snapshot_fail

_setup_git_pair "test-conflict"
(
    cd "$_WORK_DIR"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "branch version" > conflict_file.txt
    git add conflict_file.txt
    git commit -m "branch adds conflict_file" --quiet
)

# Push diverging change to origin/main (same file, different content)
_WORK2="$_TEST_BASE/work2"
git clone "$_ORIGIN_DIR" "$_WORK2" --quiet 2>/dev/null
(
    cd "$_WORK2"
    git config user.email "test2@test.com"
    git config user.name "Test2"
    echo "main version" > conflict_file.txt
    git add conflict_file.txt
    git commit -m "main adds conflict_file" --quiet
    git push origin main --quiet 2>/dev/null
)

_T7_RC=0
_T7_OUTPUT=$(
    cd "$_WORK_DIR"
    export BRANCH="test-conflict"
    export GIT_ATTR_NOSYSTEM=1
    _load_recovery_fn
    _squash_rebase_recovery 2>&1
) || _T7_RC=$?

# Should fail when unresolvable conflict exists
assert_eq "test_prints_file_list_returns_1" "1" "$_T7_RC"

# Output should contain "ACTION REQUIRED" and the conflicted file name
_T7_HAS_ACTION=0
if [[ "$_T7_OUTPUT" == *ACTION\ REQUIRED* ]]; then
    _T7_HAS_ACTION=1
fi
assert_eq "test_prints_file_list_action_required" "1" "$_T7_HAS_ACTION"

_T7_HAS_FILE=0
if [[ "$_T7_OUTPUT" == *conflict_file.txt* ]]; then
    _T7_HAS_FILE=1
fi
assert_eq "test_prints_file_list_contains_filename" "1" "$_T7_HAS_FILE"

assert_pass_if_clean "test_prints_file_list_on_unresolvable_conflict"
rm -rf "$_TEST_BASE"

# =============================================================================
print_summary
