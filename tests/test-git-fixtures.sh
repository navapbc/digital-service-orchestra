#!/usr/bin/env bash
# tests/test-git-fixtures.sh
# TDD tests for the git-fixtures shared library (template repo caching).
#
# Tests:
#   1. test_clone_test_repo_creates_valid_git_repo
#   2. test_clone_test_repo_produces_isolated_repos
#   3. test_template_reused_across_calls
#   4. test_clone_test_repo_has_initial_commit
#   5. test_clone_test_repo_has_user_config

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"

source "$SCRIPT_DIR/lib/assert.sh"

WORK_DIR=$(mktemp -d)

# Disable commit signing for test git repos (save/restore for isolation)
_OLD_GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-}"
_OLD_GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-}"
_OLD_GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-}"
export GIT_CONFIG_COUNT=1  # isolation-ok: save/restore wraps this export
export GIT_CONFIG_KEY_0=commit.gpgsign  # isolation-ok: save/restore wraps this export
export GIT_CONFIG_VALUE_0=false  # isolation-ok: save/restore wraps this export

_restore_git_config() {
    if [[ -n "$_OLD_GIT_CONFIG_COUNT" ]]; then
        export GIT_CONFIG_COUNT="$_OLD_GIT_CONFIG_COUNT"
    else
        unset GIT_CONFIG_COUNT 2>/dev/null || true
    fi
    if [[ -n "$_OLD_GIT_CONFIG_KEY_0" ]]; then
        export GIT_CONFIG_KEY_0="$_OLD_GIT_CONFIG_KEY_0"
    else
        unset GIT_CONFIG_KEY_0 2>/dev/null || true
    fi
    if [[ -n "$_OLD_GIT_CONFIG_VALUE_0" ]]; then
        export GIT_CONFIG_VALUE_0="$_OLD_GIT_CONFIG_VALUE_0"
    else
        unset GIT_CONFIG_VALUE_0 2>/dev/null || true
    fi
}
trap '_restore_git_config; rm -rf "$WORK_DIR"' EXIT

# --- Test 1: clone_test_repo creates a valid git repo ---
test_clone_test_repo_creates_valid_git_repo() {
    _snapshot_fail
    # Source the fixture library (resets template state)
    unset _GIT_FIXTURE_TEMPLATE_DIR
    source "$SCRIPT_DIR/lib/git-fixtures.sh"

    local dest="$WORK_DIR/repo1"
    clone_test_repo "$dest"

    # Should be a git repo
    assert_eq "repo1: is a git directory" "true" "$([ -d "$dest/.git" ] && echo true || echo false)"

    # Should have a README.md
    assert_eq "repo1: has README.md" "true" "$([ -f "$dest/README.md" ] && echo true || echo false)"

    assert_pass_if_clean "test_clone_test_repo_creates_valid_git_repo"
}

# --- Test 2: cloned repos are isolated from each other ---
test_clone_test_repo_produces_isolated_repos() {
    _snapshot_fail
    unset _GIT_FIXTURE_TEMPLATE_DIR
    source "$SCRIPT_DIR/lib/git-fixtures.sh"

    local dest_a="$WORK_DIR/iso-a"
    local dest_b="$WORK_DIR/iso-b"
    clone_test_repo "$dest_a"
    clone_test_repo "$dest_b"

    # Modify repo A
    echo "modified" > "$dest_a/README.md"
    git -C "$dest_a" add -A
    git -C "$dest_a" commit -q -m "modify A"

    # Repo B should be untouched
    local content_b
    content_b=$(cat "$dest_b/README.md")
    assert_eq "isolation: B unchanged after A modified" "initial" "$content_b"

    # Repo A and B should have different commit histories now
    local count_a count_b
    count_a=$(git -C "$dest_a" rev-list --count HEAD)
    count_b=$(git -C "$dest_b" rev-list --count HEAD)
    assert_eq "isolation: A has 2 commits" "2" "$count_a"
    assert_eq "isolation: B has 1 commit" "1" "$count_b"

    assert_pass_if_clean "test_clone_test_repo_produces_isolated_repos"
}

# --- Test 3: template is reused across calls (not re-created) ---
test_template_reused_across_calls() {
    _snapshot_fail
    unset _GIT_FIXTURE_TEMPLATE_DIR
    source "$SCRIPT_DIR/lib/git-fixtures.sh"

    local dest1="$WORK_DIR/reuse-1"
    clone_test_repo "$dest1"
    local template_after_first="$_GIT_FIXTURE_TEMPLATE_DIR"

    local dest2="$WORK_DIR/reuse-2"
    clone_test_repo "$dest2"
    local template_after_second="$_GIT_FIXTURE_TEMPLATE_DIR"

    # Template dir should be the same (reused, not re-created)
    assert_eq "template: same dir on second call" "$template_after_first" "$template_after_second"
    assert_pass_if_clean "test_template_reused_across_calls"
}

# --- Test 4: cloned repo has an initial commit ---
test_clone_test_repo_has_initial_commit() {
    _snapshot_fail
    unset _GIT_FIXTURE_TEMPLATE_DIR
    source "$SCRIPT_DIR/lib/git-fixtures.sh"

    local dest="$WORK_DIR/commit-check"
    clone_test_repo "$dest"

    local commit_count
    commit_count=$(git -C "$dest" rev-list --count HEAD)
    assert_eq "commit: has exactly 1 commit" "1" "$commit_count"

    local commit_msg
    commit_msg=$(git -C "$dest" log --format=%s -1)
    assert_eq "commit: message is 'init'" "init" "$commit_msg"

    assert_pass_if_clean "test_clone_test_repo_has_initial_commit"
}

# --- Test 5: cloned repo has user config set ---
test_clone_test_repo_has_user_config() {
    _snapshot_fail
    unset _GIT_FIXTURE_TEMPLATE_DIR
    source "$SCRIPT_DIR/lib/git-fixtures.sh"

    local dest="$WORK_DIR/config-check"
    clone_test_repo "$dest"

    local email name
    email=$(git -C "$dest" config user.email)
    name=$(git -C "$dest" config user.name)

    assert_eq "config: email set" "test@test.com" "$email"
    assert_eq "config: name set" "Test" "$name"

    assert_pass_if_clean "test_clone_test_repo_has_user_config"
}

# --- Run all tests ---
test_clone_test_repo_creates_valid_git_repo
test_clone_test_repo_produces_isolated_repos
test_template_reused_across_calls
test_clone_test_repo_has_initial_commit
test_clone_test_repo_has_user_config

print_summary
