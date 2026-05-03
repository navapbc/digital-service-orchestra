#!/usr/bin/env bash
# tests/scripts/test-claude-safe-stale-local-main.sh
# RED test for bug cc8f-73a5: _offer_worktree_cleanup and is_branch_merged fail
# to detect branches as merged when the local main ref is stale (behind origin/main).
#
# Root cause: when the main repo is checked out on a non-main branch, running
# `git pull origin <non-main-branch>` updates that branch but does NOT
# fast-forward local main. A worktree created from HEAD (the non-main branch)
# starts at a SHA that is an ancestor of origin/main but NOT of local main.
# The is-ancestor check against local main fails, producing false "unmerged commits".
#
# Observable behavior under test (claude-safe):
#   _offer_worktree_cleanup should output "Cleaning up" when the worktree branch
#   is an ancestor of origin/main, even if local main is behind.
#
# Observable behavior under test (worktree-cleanup.sh):
#   --dry-run should output "would remove" for a worktree whose branch is an
#   ancestor of origin/main even when local main is stale.
#
# RED state: output shows "cannot be auto-removed" / "keep (not merged)".
# GREEN state: output shows "Cleaning up" / "would remove".
#
# Usage: bash tests/scripts/test-claude-safe-stale-local-main.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$SCRIPT_DIR/../lib/assert.sh"

CLAUDE_SAFE="$REPO_ROOT/plugins/dso/scripts/claude-safe"
CLEANUP_SCRIPT="$REPO_ROOT/plugins/dso/scripts/worktree-cleanup.sh"
PLUGIN_SCRIPTS="$REPO_ROOT/plugins/dso/scripts"

echo "=== test-claude-safe-stale-local-main.sh ==="

# ── Temp dir management ───────────────────────────────────────────────────────

_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_tmpdirs EXIT

make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Helper: set up repo with stale local main ─────────────────────────────────
#
# Creates a scenario where:
#   - A bare "origin" repo exists
#   - A "main" clone has local main at an OLD SHA (before recent commits)
#   - origin/main has advanced with new commits (simulating PR merges)
#   - A worktree branch starts at the new SHA (from a non-main branch)
#   - The worktree branch tip IS an ancestor of origin/main
#   - The worktree branch tip is NOT an ancestor of local main
#
# Outputs (one per line):
#   $1: path to main repo clone
#   $2: path to worktree
#   $3: worktree branch name
#
_setup_stale_local_main() {
    local tmp="$1"
    local branch_name="${2:-worktree-test-stale}"

    # Create bare origin
    git init --bare -b main -q "$tmp/origin.git"

    # Clone into main repo
    git clone -q "$tmp/origin.git" "$tmp/main-repo" 2>/dev/null
    (
        cd "$tmp/main-repo" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "v1" > file.txt
        git add file.txt
        git commit -q -m "initial: v1"
        git push -q origin main 2>/dev/null
    )

    # Add a commit to a feature branch in the main repo (simulates work in progress)
    local feature_branch="feature/some-work"
    (
        cd "$tmp/main-repo" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        git checkout -b "$feature_branch" -q
        echo "v2" > file.txt
        git add file.txt
        git commit -q -m "feat: advance to v2"
    )

    # Simulate: someone else merged the feature work to origin/main via PR
    # (local main is NOT fast-forwarded — main repo is on the feature branch)
    (
        cd "$tmp/main-repo" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        # Push feature branch HEAD directly to origin/main (simulates squash/ff PR merge)
        git push -q origin "$feature_branch:main" 2>/dev/null
        # Fetch so origin/main tracking ref is updated
        git fetch -q origin 2>/dev/null
    )

    # Verify setup: local main is behind origin/main
    local local_main origin_main
    local_main=$(git -C "$tmp/main-repo" rev-parse main 2>/dev/null)
    origin_main=$(git -C "$tmp/main-repo" rev-parse origin/main 2>/dev/null)
    if [ "$local_main" = "$origin_main" ]; then
        echo "TEST SETUP ERROR: local main == origin/main — stale-main simulation failed" >&2
        exit 2
    fi

    # Verify: feature branch tip IS ancestor of origin/main but NOT of local main
    local feature_tip
    feature_tip=$(git -C "$tmp/main-repo" rev-parse "$feature_branch" 2>/dev/null)
    if ! git -C "$tmp/main-repo" merge-base --is-ancestor "$feature_tip" origin/main 2>/dev/null; then
        echo "TEST SETUP ERROR: feature tip is not ancestor of origin/main" >&2
        exit 2
    fi
    if git -C "$tmp/main-repo" merge-base --is-ancestor "$feature_tip" main 2>/dev/null; then
        echo "TEST SETUP ERROR: feature tip IS already ancestor of local main — setup failed" >&2
        exit 2
    fi

    # Create a worktree from the feature branch tip (this is what worktree-create.sh
    # does when the main repo is on a non-main branch: HEAD = feature branch tip)
    local wt_dir="$tmp/worktrees"
    mkdir -p "$wt_dir"
    local wt_path="$wt_dir/$branch_name"
    git -C "$tmp/main-repo" worktree add "$wt_path" -b "$branch_name" "$feature_branch" -q

    MAIN_REPO="$tmp/main-repo"
    echo "$MAIN_REPO"
    echo "$wt_path"
    echo "$branch_name"
}

# ── test_claude_safe_stale_local_main ─────────────────────────────────────────
# _offer_worktree_cleanup must detect a branch as merged when it is an ancestor
# of origin/main, even if local main is stale.
test_claude_safe_stale_local_main() {
    local tmp
    tmp=$(make_tmpdir)

    local branch_name="worktree-test-stale-claude-safe"
    local main_repo wt_path _branch
    read -r main_repo wt_path _branch <<< "$(_setup_stale_local_main "$tmp" "$branch_name" | tr '\n' ' ')"

    # Resolve python with pyyaml for read-config.sh
    local plugin_python=""
    for _cand in "$REPO_ROOT/app/.venv/bin/python3" "$REPO_ROOT/.venv/bin/python3" python3; do
        [[ "$_cand" != "python3" ]] && [[ ! -f "$_cand" ]] && continue
        if "$_cand" -c "import yaml" 2>/dev/null; then plugin_python="$_cand"; break; fi
    done
    if [[ -z "$plugin_python" ]]; then
        echo "SKIP: no python3 with pyyaml — skipping claude-safe test" >&2
        _snapshot_fail; assert_pass_if_clean "test_claude_safe_stale_local_main_skipped"
        return
    fi

    local output
    output=$(
        _CLAUDE_SAFE_SOURCE_ONLY=1 \
        _CLAUDE_SAFE_TEST_INTERACTIVE=1 \
        PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
        CLAUDE_PLUGIN_PYTHON="$plugin_python" \
        bash -c "source \"$CLAUDE_SAFE\"; _offer_worktree_cleanup '$branch_name' '$wt_path'"
    ) 2>&1 || true

    # RED state: shows "cannot be auto-removed" because is-ancestor check only
    # compares against local main (stale), not origin/main.
    # GREEN state (after fix): shows "Cleaning up" because origin/main fallback detects merge.
    assert_contains \
        "stale_local_main: _offer_worktree_cleanup detects branch as merged via origin/main fallback" \
        "Cleaning up" \
        "$output"

    echo "test_claude_safe_stale_local_main ... PASS"
}

# ── test_worktree_cleanup_stale_local_main ────────────────────────────────────
# worktree-cleanup.sh --dry-run must output "would remove" for a worktree whose
# branch is an ancestor of origin/main even when local main is stale.
test_worktree_cleanup_stale_local_main() {
    local tmp
    tmp=$(make_tmpdir)

    local branch_name="worktree-test-stale-cleanup"
    local main_repo wt_path _branch
    read -r main_repo wt_path _branch <<< "$(_setup_stale_local_main "$tmp" "$branch_name" | tr '\n' ' ')"

    local output
    output=$(
        cd "$main_repo" && \
        AGE_HOURS=0 \
        NON_INTERACTIVE=true \
        bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null
    ) || true

    # RED state: shows "keep (not merged)" because is_branch_merged only checks local main.
    # GREEN state (after fix): shows "would remove" because origin/main fallback detects merge.
    assert_contains \
        "stale_local_main: worktree-cleanup --dry-run detects branch as merged via origin/main fallback" \
        "would remove" \
        "$output"

    assert_contains \
        "stale_local_main: worktree branch appears in dry-run listing" \
        "$branch_name" \
        "$output"

    echo "test_worktree_cleanup_stale_local_main ... PASS"
}

# ── test_stale_local_main_unmerged_branch_not_false_positive ─────────────────
# A branch that is NOT merged (not an ancestor of either local main or
# origin/main) must NOT be incorrectly flagged for removal.
test_stale_local_main_unmerged_branch_not_false_positive() {
    local tmp
    tmp=$(make_tmpdir)

    local branch_name="worktree-test-stale-unmerged"
    local main_repo wt_path _branch
    read -r main_repo wt_path _branch <<< "$(_setup_stale_local_main "$tmp" "worktree-test-stale-base" | tr '\n' ' ')"

    # Add a SECOND worktree branch with its OWN unique commit — genuinely unmerged
    local unmerged_wt_path="$tmp/worktrees/$branch_name"
    mkdir -p "$tmp/worktrees"
    git -C "$main_repo" worktree add "$unmerged_wt_path" -b "$branch_name" -q
    (
        cd "$unmerged_wt_path" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "genuinely unique work" > unique.txt
        git add unique.txt
        git commit -q -m "wip: genuine in-progress work"
    )

    local output
    output=$(
        cd "$main_repo" && \
        AGE_HOURS=0 \
        NON_INTERACTIVE=true \
        bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null
    ) || true

    # The genuinely unmerged branch must NOT appear as "would remove"
    assert_not_contains \
        "stale_local_main: genuinely unmerged branch is not falsely marked for removal" \
        "would remove" \
        "$(echo "$output" | grep "$branch_name")"

    echo "test_stale_local_main_unmerged_branch_not_false_positive ... PASS"
}

# ── Run tests ─────────────────────────────────────────────────────────────────

echo ""
echo "--- test_claude_safe_stale_local_main ---"
_snapshot_fail
test_claude_safe_stale_local_main
assert_pass_if_clean "test_claude_safe_stale_local_main"

echo ""
echo "--- test_worktree_cleanup_stale_local_main ---"
_snapshot_fail
test_worktree_cleanup_stale_local_main
assert_pass_if_clean "test_worktree_cleanup_stale_local_main"

echo ""
echo "--- test_stale_local_main_unmerged_branch_not_false_positive ---"
_snapshot_fail
test_stale_local_main_unmerged_branch_not_false_positive
assert_pass_if_clean "test_stale_local_main_unmerged_branch_not_false_positive"

print_summary
