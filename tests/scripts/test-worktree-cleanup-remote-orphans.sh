#!/usr/bin/env bash
# tests/scripts/test-worktree-cleanup-remote-orphans.sh
# RED tests for remote-orphan cleanup additions to plugins/dso/scripts/worktree-cleanup.sh
#
# Behavior under test:
#   1. Remote-only orphan branches that are merged into origin/main are deleted from origin.
#   2. Remote-only orphan branches that are unmerged AND have no closed/merged PR are preserved.
#   3. Dangling remote-tracking refs (refs/remotes/<unknown-remote>/x) are pruned.
#   4. Protected refs (main/master/tickets, refs/remotes/origin/HEAD) are never deleted/pruned.
#   5. The story/* pattern is picked up by default (worktree.orphan_patterns).
#   6. Back-compat: worktree.branch_pattern is still honored, with a deprecation warning.
#   7. Local orphan whose tip is not strictly an ancestor of main (squash-merge proxy) is
#      deleted via the -D fallback in _delete_local_branch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"
CLEANUP_SCRIPT="$REPO_ROOT/plugins/dso/scripts/worktree-cleanup.sh"

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

# Build a bare repo (origin) + a clone with an initial commit on main.
# Sets globals: BARE, CLONE
setup_origin_and_clone() {
    local base="$1"
    BARE="$base/origin.git"
    CLONE="$base/repo"
    git init --bare -b main "$BARE" >/dev/null 2>&1
    git init -b main "$CLONE" >/dev/null 2>&1
    git -C "$CLONE" config user.email "test@test.com"
    git -C "$CLONE" config user.name "Test"
    git -C "$CLONE" remote add origin "$BARE"
    echo "initial" > "$CLONE/file.txt"
    git -C "$CLONE" add file.txt
    git -C "$CLONE" commit -m "initial" >/dev/null 2>&1
    git -C "$CLONE" push -u origin main >/dev/null 2>&1
}

# Push a branch to origin that IS an ancestor of main on origin (merged via FF on origin).
# Creates branch from main HEAD (which is already on origin); no divergence — merge-base test passes.
push_merged_branch_to_origin() {
    local branch="$1"
    git -C "$CLONE" push origin "main:refs/heads/$branch" >/dev/null 2>&1
}

# Push a branch to origin that is NOT merged into main (diverged commit only on the branch).
push_unmerged_branch_to_origin() {
    local branch="$1"
    git -C "$CLONE" branch "$branch" main >/dev/null 2>&1
    git -C "$CLONE" checkout "$branch" >/dev/null 2>&1
    echo "diverge" > "$CLONE/diverge-$branch.txt"
    git -C "$CLONE" add "diverge-$branch.txt"
    git -C "$CLONE" commit -m "diverge $branch" >/dev/null 2>&1
    git -C "$CLONE" push origin "$branch" >/dev/null 2>&1
    git -C "$CLONE" checkout main >/dev/null 2>&1
    # Delete the local branch so the remote ref is "orphan" on origin.
    git -C "$CLONE" branch -D "$branch" >/dev/null 2>&1
}

remote_has_branch() {
    git -C "$BARE" show-ref --verify --quiet "refs/heads/$1"
}

# ── Test 1: Remote-only merged branch is deleted from origin ─────────────────
test_remote_merged_orphan_is_deleted() {
    local tmp; tmp=$(make_tmpdir)
    setup_origin_and_clone "$tmp"
    push_merged_branch_to_origin "worktree-merged-abc"

    # Sanity precondition
    local pre="no"; remote_has_branch "worktree-merged-abc" && pre="yes"
    assert_eq "precondition: merged orphan present on origin" "yes" "$pre"

    (cd "$CLONE" && WORKTREE_CLEANUP_ENABLED=1 bash "$CLEANUP_SCRIPT" \
        --non-interactive --all --force 2>/dev/null) >/dev/null || true

    local post="yes"; remote_has_branch "worktree-merged-abc" || post="no"
    assert_eq "remote merged orphan deleted from origin" "no" "$post"
}

# ── Test 2: Unmerged remote orphan with no PR is preserved ───────────────────
test_remote_unmerged_orphan_is_preserved() {
    local tmp; tmp=$(make_tmpdir)
    setup_origin_and_clone "$tmp"
    push_unmerged_branch_to_origin "worktree-unmerged-xyz"

    # Sandbox gh: empty PATH dir without gh so PR check returns no-evidence.
    local fake_path; fake_path="$tmp/empty-path"
    mkdir -p "$fake_path"

    (cd "$CLONE" && PATH="$fake_path:/usr/bin:/bin" WORKTREE_CLEANUP_ENABLED=1 \
        bash "$CLEANUP_SCRIPT" --non-interactive --all --force 2>/dev/null) >/dev/null || true

    local post="no"; remote_has_branch "worktree-unmerged-xyz" && post="yes"
    assert_eq "remote unmerged orphan preserved (no merge evidence)" "yes" "$post"
}

# ── Test 3: Dangling remote-tracking ref is pruned ───────────────────────────
test_dangling_remote_tracking_ref_pruned() {
    local tmp; tmp=$(make_tmpdir)
    setup_origin_and_clone "$tmp"

    # Inject a refs/remotes/agent/foo ref pointing at main's commit; 'agent' is NOT a configured remote.
    local sha; sha=$(git -C "$CLONE" rev-parse HEAD)
    git -C "$CLONE" update-ref "refs/remotes/agent/foo" "$sha" >/dev/null 2>&1

    local pre="no"
    git -C "$CLONE" show-ref --verify --quiet "refs/remotes/agent/foo" && pre="yes"
    assert_eq "precondition: dangling ref present" "yes" "$pre"

    (cd "$CLONE" && WORKTREE_CLEANUP_ENABLED=1 bash "$CLEANUP_SCRIPT" \
        --non-interactive --all --force 2>/dev/null) >/dev/null || true

    local post="yes"
    git -C "$CLONE" show-ref --verify --quiet "refs/remotes/agent/foo" || post="no"
    assert_eq "dangling refs/remotes/agent/foo pruned" "no" "$post"

    # And refs/remotes/origin/main must still exist
    local origin_main="no"
    git -C "$CLONE" show-ref --verify --quiet "refs/remotes/origin/main" && origin_main="yes"
    assert_eq "refs/remotes/origin/main not touched" "yes" "$origin_main"
}

# ── Test 4: main/tickets are never touched on origin ─────────────────────────
test_protected_branches_never_deleted_from_origin() {
    local tmp; tmp=$(make_tmpdir)
    setup_origin_and_clone "$tmp"

    # Push a 'tickets' branch to origin (matches none of our patterns, but be explicit).
    git -C "$CLONE" push origin "main:refs/heads/tickets" >/dev/null 2>&1

    (cd "$CLONE" && WORKTREE_CLEANUP_ENABLED=1 bash "$CLEANUP_SCRIPT" \
        --non-interactive --all --force 2>/dev/null) >/dev/null || true

    local main_ok="no"; remote_has_branch "main" && main_ok="yes"
    local tickets_ok="no"; remote_has_branch "tickets" && tickets_ok="yes"
    assert_eq "origin/main never deleted" "yes" "$main_ok"
    assert_eq "origin/tickets never deleted" "yes" "$tickets_ok"
}

# ── Test 5: story/* pattern is picked up by default ──────────────────────────
test_story_pattern_picked_up_by_default() {
    local tmp; tmp=$(make_tmpdir)
    setup_origin_and_clone "$tmp"
    push_merged_branch_to_origin "story/foo-1234/bar-5678"

    (cd "$CLONE" && WORKTREE_CLEANUP_ENABLED=1 bash "$CLEANUP_SCRIPT" \
        --non-interactive --all --force 2>/dev/null) >/dev/null || true

    local post="yes"; remote_has_branch "story/foo-1234/bar-5678" || post="no"
    assert_eq "story/* merged orphan deleted from origin" "no" "$post"
}

# ── Test 6: Back-compat — worktree.branch_pattern still works, with warning ──
test_branch_pattern_back_compat_warns() {
    local tmp; tmp=$(make_tmpdir)
    setup_origin_and_clone "$tmp"
    push_merged_branch_to_origin "legacy-pattern-merged"

    # Write a config that uses ONLY the legacy key.
    mkdir -p "$CLONE/.claude"
    cat > "$CLONE/.claude/dso-config.conf" <<EOF
worktree.branch_pattern=legacy-pattern-*
EOF

    local stderr_out
    stderr_out=$(cd "$CLONE" && WORKTREE_CLEANUP_ENABLED=1 \
        bash "$CLEANUP_SCRIPT" --non-interactive --all --force 2>&1 >/dev/null) || true

    local post="yes"; remote_has_branch "legacy-pattern-merged" || post="no"
    assert_eq "legacy branch_pattern still picks up merged orphan" "no" "$post"

    local warned="no"
    if [[ "$stderr_out" == *"worktree.branch_pattern"* && "$stderr_out" == *"deprecated"* ]]; then
        warned="yes"
    fi
    assert_eq "deprecation warning emitted for branch_pattern" "yes" "$warned"
}

# ── Test 7: Local orphan with diverged tip is deleted via -D fallback ────────
test_local_orphan_squash_merged_uses_dash_D_fallback() {
    local tmp; tmp=$(make_tmpdir)
    setup_origin_and_clone "$tmp"

    # Local branch with a commit not on main → branch -d would refuse with "not fully merged".
    # But the commit message includes "Merge pull request" + branch name, so is_branch_merged
    # detects it as merged → orphan handler must use -D fallback to actually delete it.
    git -C "$CLONE" branch "worktree-squashed" main >/dev/null 2>&1
    git -C "$CLONE" checkout "worktree-squashed" >/dev/null 2>&1
    echo "squash" > "$CLONE/squash.txt"
    git -C "$CLONE" add squash.txt
    git -C "$CLONE" commit -m "squash content" >/dev/null 2>&1
    git -C "$CLONE" checkout main >/dev/null 2>&1
    # Synthesize the GitHub squash-merge commit message on main so is_branch_merged returns true.
    git -C "$CLONE" commit --allow-empty -m "Merge pull request #42 from org/worktree-squashed" >/dev/null 2>&1
    git -C "$CLONE" push origin main >/dev/null 2>&1

    local pre="no"
    git -C "$CLONE" show-ref --verify --quiet "refs/heads/worktree-squashed" && pre="yes"
    assert_eq "precondition: squash-merged local orphan present" "yes" "$pre"

    (cd "$CLONE" && WORKTREE_CLEANUP_ENABLED=1 bash "$CLEANUP_SCRIPT" \
        --non-interactive --all --force 2>/dev/null) >/dev/null || true

    local post="yes"
    git -C "$CLONE" show-ref --verify --quiet "refs/heads/worktree-squashed" || post="no"
    assert_eq "squash-merged local orphan deleted via -D fallback" "no" "$post"
}

test_remote_merged_orphan_is_deleted
test_remote_unmerged_orphan_is_preserved
test_dangling_remote_tracking_ref_pruned
test_protected_branches_never_deleted_from_origin
test_story_pattern_picked_up_by_default
test_branch_pattern_back_compat_warns
test_local_orphan_squash_merged_uses_dash_D_fallback

print_summary
