#!/usr/bin/env bash
# tests/scripts/test-redistribute-session-commits.sh
# RED-phase behavioral tests for plugins/dso/scripts/redistribute-session-commits.sh
#
# All 8 tests FAIL until the script is implemented (RED gate confirmed).
#
# The script redistributes session-branch commits to per-story branches using a
# 5-phase algorithm: RESOLVE → ATTRIBUTE → SPLIT → FALLBACK → PUBLISH
#
# Usage: bash tests/scripts/test-redistribute-session-commits.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/redistribute-session-commits.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-redistribute-session-commits.sh ==="

# ── Global temp dir setup ─────────────────────────────────────────────────────
_TEST_TMPDIRS=()
make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}
cleanup_tmpdirs() {
    local d
    for d in "${_TEST_TMPDIRS[@]+"${_TEST_TMPDIRS[@]}"}"; do
        rm -rf "$d"
    done
}
trap cleanup_tmpdirs EXIT

# ── Helper: create a minimal git repo with a "main" branch ───────────────────
# Usage: init_git_repo <dir>
init_git_repo() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    # Create initial commit on main
    echo "root" > "$dir/root.txt"
    git -C "$dir" add root.txt
    git -C "$dir" commit -q -m "root commit"
    # Rename default branch to main if needed
    git -C "$dir" branch -m main 2>/dev/null || true
}

# ── Test 1: script exists and is executable ───────────────────────────────────
# RED: script does not exist yet — both assertions FAIL
test_script_exists() {
    local exists is_executable
    if [[ -f "$SCRIPT" ]]; then exists="yes"; else exists="no"; fi
    assert_eq "test_script_exists: redistribute-session-commits.sh file exists" "yes" "$exists"

    if [[ -x "$SCRIPT" ]]; then is_executable="yes"; else is_executable="no"; fi
    assert_eq "test_script_exists: redistribute-session-commits.sh is executable" "yes" "$is_executable"
}

# ── Test 2: --dry-run prints plan without modifying git state ─────────────────
# HEAD SHA must be identical before and after --dry-run invocation.
test_dry_run_produces_plan_without_git_mutations() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    # Create one story commit on a session branch
    git -C "$repo" checkout -q -b "worktree-session-test"
    echo "story-file" > "$repo/story-a.txt"
    git -C "$repo" add story-a.txt
    git -C "$repo" commit -q -m "add story A file

DSO-Story: story-abc-0001"

    local head_before
    head_before="$(git -C "$repo" rev-parse HEAD)"

    # Stub resolve-session-branch.sh to return our session branch name
    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-session-test"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    # Stub ticket list to return a minimal story scope
    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[{"id":"story-abc-0001","type":"story","title":"Add story A","description":"story-a.txt"}]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    # Stub gh: no-op for all calls in dry-run
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-abc" --dry-run 2>&1) || exit_code=$?

    local head_after
    head_after="$(git -C "$repo" rev-parse HEAD)"

    assert_eq "test_dry_run: HEAD SHA unchanged after --dry-run" \
        "$head_before" "$head_after"

    # dry-run must produce some plan output
    local has_plan_output
    if echo "$output" | grep -qiE "dry.?run|plan|would|commit|redistribute"; then
        has_plan_output="yes"
    else
        has_plan_output="no"
    fi
    assert_eq "test_dry_run: output contains plan/dry-run marker" "yes" "$has_plan_output"

    # No new branches should have been created
    local new_branches
    new_branches="$(git -C "$repo" branch --list "story/*" | wc -l | tr -d ' ')"
    assert_eq "test_dry_run: no story/* branches created during dry-run" "0" "$new_branches"
}

# ── Test 3: empty commit range exits 0 with informational message ─────────────
# When main..session-HEAD is empty (0 commits), script exits 0 cleanly.
test_empty_range_exits_zero() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    # Session branch tip is same as main (no new commits)
    git -C "$repo" checkout -q -b "worktree-empty-session"

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-empty-session"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    local ticket_json="$tmpdir/tickets.json"
    echo "[]" > "$ticket_json"

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-empty" 2>&1) || exit_code=$?

    assert_eq "test_empty_range_exits_zero: exits 0 when range is empty" "0" "$exit_code"

    local mentions_no_commits
    if echo "$output" | grep -qiE "no commits|nothing to redistribute|empty"; then
        mentions_no_commits="yes"
    else
        mentions_no_commits="no"
    fi
    assert_eq "test_empty_range_exits_zero: output mentions no commits to redistribute" \
        "yes" "$mentions_no_commits"
}

# ── Test 4: trailer-match ACCEPT path → 1 group for story ────────────────────
# Commit with DSO-Story trailer AND ≥80% files matching story scope →
# produces exactly 1 story-branch group for that story (in dry-run to avoid push).
test_trailer_match_accept_path() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    git -C "$repo" checkout -q -b "worktree-accept-test"

    # Commit whose changed file clearly belongs to story-s1's scope
    echo "feature code" > "$repo/feature-s1.txt"
    git -C "$repo" add feature-s1.txt
    git -C "$repo" commit -q -m "implement feature s1

DSO-Story: story-s1-0001"

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-accept-test"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    # Ticket data: story-s1-0001 owns feature-s1.txt
    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[{"id":"story-s1-0001","type":"story","title":"Feature S1","description":"feature-s1.txt implements the S1 feature"}]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-accept" --dry-run 2>&1) || exit_code=$?

    # Output should show 1 group attributed to story-s1-0001
    local mentions_story_s1
    if echo "$output" | grep -q "story-s1-0001"; then
        mentions_story_s1="yes"
    else
        mentions_story_s1="no"
    fi
    assert_eq "test_trailer_match_accept_path: plan output references story-s1-0001 group" \
        "yes" "$mentions_story_s1"

    # Output should NOT mention SPLIT or UNATTRIBUTED for this commit
    local mentions_split
    if echo "$output" | grep -qiE "split|unattributed" ; then
        mentions_split="yes"
    else
        mentions_split="no"
    fi
    assert_eq "test_trailer_match_accept_path: clean trailer match does NOT trigger SPLIT/UNATTRIBUTED" \
        "no" "$mentions_split"
}

# ── Test 5: trailer mismatch triggers SPLIT with 2 per-story synthetic commits ─
# Commit with trailer S3 but content adding S5's file → SPLIT output with
# both story IDs represented in the plan.
test_trailer_mismatch_triggers_split() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    git -C "$repo" checkout -q -b "worktree-split-test"

    # Commit is tagged for story-s3 but also touches story-s5's file (cross-pollution)
    echo "s3 feature" > "$repo/feature-s3.txt"
    echo "s5 feature" > "$repo/feature-s5.txt"
    git -C "$repo" add feature-s3.txt feature-s5.txt
    git -C "$repo" commit -q -m "cross-pollinated commit

DSO-Story: story-s3-0001"

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-split-test"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    # Ticket data: s3 owns feature-s3.txt, s5 owns feature-s5.txt
    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[
  {"id":"story-s3-0001","type":"story","title":"Feature S3","description":"feature-s3.txt implements S3"},
  {"id":"story-s5-0001","type":"story","title":"Feature S5","description":"feature-s5.txt implements S5"}
]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-split" --dry-run 2>&1) || exit_code=$?

    # Output must reference SPLIT action for this commit
    local mentions_split
    if echo "$output" | grep -qiE "split"; then
        mentions_split="yes"
    else
        mentions_split="no"
    fi
    assert_eq "test_trailer_mismatch_triggers_split: plan shows SPLIT for cross-pollinated commit" \
        "yes" "$mentions_split"

    # Both story IDs must appear in the plan
    local mentions_s3
    if echo "$output" | grep -q "story-s3-0001"; then mentions_s3="yes"; else mentions_s3="no"; fi
    assert_eq "test_trailer_mismatch_triggers_split: plan references story-s3-0001" "yes" "$mentions_s3"

    local mentions_s5
    if echo "$output" | grep -q "story-s5-0001"; then mentions_s5="yes"; else mentions_s5="no"; fi
    assert_eq "test_trailer_mismatch_triggers_split: plan references story-s5-0001" "yes" "$mentions_s5"
}

# ── Test 6: unattributed commits fall back to temporal epoch branches ─────────
# Commits without trailers AND without scope match → plan shows epoch-NN grouping.
test_unattributed_falls_back_to_temporal_epochs() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    git -C "$repo" checkout -q -b "worktree-epoch-test"

    # Create 6 commits with no DSO-Story trailer and files that don't match any story scope
    local i
    for i in 1 2 3 4 5 6; do
        echo "unrelated change $i" > "$repo/unrelated-$i.txt"
        git -C "$repo" add "unrelated-$i.txt"
        git -C "$repo" commit -q -m "unrelated commit $i (no trailer)"
    done

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-epoch-test"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    # Ticket data: no story owns any unrelated-*.txt file
    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[{"id":"story-xyz-0001","type":"story","title":"Unrelated story","description":"completely different scope docs/specs"}]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-epoch" --dry-run 2>&1) || exit_code=$?

    # Output must mention epoch-based fallback grouping
    local mentions_epoch
    if echo "$output" | grep -qiE "epoch"; then
        mentions_epoch="yes"
    else
        mentions_epoch="no"
    fi
    assert_eq "test_unattributed_falls_back_to_temporal_epochs: plan output contains epoch grouping" \
        "yes" "$mentions_epoch"

    # 6 commits at ~5 per epoch → at least 1 epoch group referenced
    local epoch_count
    epoch_count="$(echo "$output" | grep -ciE "epoch-[0-9]+" || true)"
    assert_ne "test_unattributed_falls_back_to_temporal_epochs: at least 1 epoch-NN group in plan" \
        "0" "$epoch_count"
}

# ── Test 7: merge commits are preserved, not redistributed ───────────────────
# Merge commits in the range must NOT appear in any per-story cherry-pick group;
# confirmed by dry-run output: merge SHAs are excluded from redistribution plan.
test_merge_commits_preserved_not_redistributed() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    git -C "$repo" checkout -q -b "worktree-merge-test"

    # Create a side branch and merge it (creates a merge commit)
    git -C "$repo" checkout -q -b "side-branch"
    echo "side" > "$repo/side.txt"
    git -C "$repo" add side.txt
    git -C "$repo" commit -q -m "side branch commit"

    git -C "$repo" checkout -q "worktree-merge-test"
    git -C "$repo" merge --no-ff -q "side-branch" -m "Merge side-branch into session

DSO-Story: story-merge-0001"

    # Also add a regular story commit
    echo "regular" > "$repo/regular.txt"
    git -C "$repo" add regular.txt
    git -C "$repo" commit -q -m "regular story commit

DSO-Story: story-merge-0001"

    local merge_sha
    merge_sha="$(git -C "$repo" log --merges --format="%H" "main..worktree-merge-test" | head -1)"

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-merge-test"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[{"id":"story-merge-0001","type":"story","title":"Merge story","description":"regular.txt side.txt"}]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-merge" --dry-run 2>&1) || exit_code=$?

    # The merge SHA must NOT appear in any cherry-pick/story group in the plan
    local merge_sha_short="${merge_sha:0:12}"
    local merge_in_redistribution
    if echo "$output" | grep -qiE "(cherry.?pick|story group|redistribute).*$merge_sha_short"; then
        merge_in_redistribution="yes"
    else
        merge_in_redistribution="no"
    fi
    assert_eq "test_merge_commits_preserved: merge SHA not included in cherry-pick redistribution plan" \
        "no" "$merge_in_redistribution"

    # Output must explicitly note merge commits are preserved/skipped
    local mentions_merge_preserved
    if echo "$output" | grep -qiE "merge commit|skip.*merge|preserve.*merge|merge.*skip|merge.*preserve"; then
        mentions_merge_preserved="yes"
    else
        mentions_merge_preserved="no"
    fi
    assert_eq "test_merge_commits_preserved: output explicitly notes merge commits are skipped" \
        "yes" "$mentions_merge_preserved"
}

# ── Test 8: dirty worktree is refused without --force ─────────────────────────
# If git status --porcelain is non-empty, script exits non-zero with an error
# unless --force is passed.
test_dirty_worktree_refused_without_force() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    git -C "$repo" checkout -q -b "worktree-dirty-test"

    # Create one committed story commit
    echo "story file" > "$repo/story-dirty.txt"
    git -C "$repo" add story-dirty.txt
    git -C "$repo" commit -q -m "story commit

DSO-Story: story-dirty-0001"

    # Leave an uncommitted modification in the worktree (dirty state)
    echo "uncommitted change" >> "$repo/story-dirty.txt"

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-dirty-test"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[{"id":"story-dirty-0001","type":"story","title":"Dirty story","description":"story-dirty.txt"}]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    # Without --force: must exit non-zero
    local exit_code_no_force=0
    local output_no_force
    output_no_force=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-dirty" 2>&1) || exit_code_no_force=$?

    assert_ne "test_dirty_worktree_refused: exits non-zero when dirty and no --force" \
        "0" "$exit_code_no_force"

    local mentions_dirty
    if echo "$output_no_force" | grep -qiE "dirty|uncommitted|unclean|working tree|working directory"; then
        mentions_dirty="yes"
    else
        mentions_dirty="no"
    fi
    assert_eq "test_dirty_worktree_refused: error output mentions dirty/uncommitted state" \
        "yes" "$mentions_dirty"

    # With --force: must NOT refuse (exits 0 or proceeds past the dirty check)
    local exit_code_force=0
    PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-dirty" --force --dry-run 2>&1 || exit_code_force=$?

    # With --force + --dry-run, it should not fail specifically due to dirty worktree
    # (it may still fail if later phases are not implemented, but not with the dirty-check code)
    # We verify by checking the error output does NOT exclusively mention dirty state
    local force_output
    force_output=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-dirty" --force --dry-run 2>&1) || true

    # The dirty-worktree refusal message must NOT appear when --force is passed
    local force_blocked_by_dirty
    if echo "$force_output" | grep -qiE "dirty|uncommitted|unclean|working tree|working directory"; then
        force_blocked_by_dirty="yes"
    else
        force_blocked_by_dirty="no"
    fi
    assert_eq "test_dirty_worktree_refused: --force bypasses dirty-worktree refusal" \
        "no" "$force_blocked_by_dirty"
}

# ── Test 9: PUBLISH skips group when branch name matches session branch ──────
# When a story's redistribute target branch name equals SESSION_BRANCH, the
# commits already live on the source — the tool must SKIP that group with an
# INFO message and proceed with remaining groups. Without this safety, `git
# checkout -B` would reset the local session branch, destroying its state.
test_publish_skips_session_branch_collision() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    # Session branch is named to match a story ID (the collision case)
    local collision_story="2abb-11b6-37ca-49dc"
    local session_branch="story/epic-x/$collision_story"
    git -C "$repo" checkout -q -b "$session_branch"
    echo "story-content" > "$repo/file-x.sh"
    git -C "$repo" add file-x.sh
    git -C "$repo" commit -q -m "feat: x

DSO-Story: $collision_story"

    local session_head_before
    session_head_before="$(git -C "$repo" rev-parse HEAD)"

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << MOCKEOF
#!/usr/bin/env bash
echo "$session_branch"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << MOCKEOF
[{"id":"$collision_story","type":"story","title":"S","description":"file-x.sh"}]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    # Stub merge-to-main-pr.sh: no-op (avoid real PR creation)
    cat > "$mock_scripts/merge-to-main-pr.sh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_scripts/merge-to-main-pr.sh"

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        DSO_MERGE_TO_MAIN_PR_OVERRIDE="$mock_scripts/merge-to-main-pr.sh" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-x" 2>&1) || exit_code=$?

    # Session branch HEAD must be unchanged (no destructive reset)
    local session_head_after
    session_head_after="$(git -C "$repo" rev-parse "$session_branch")"
    assert_eq "test_publish_skips_session_branch_collision: session branch HEAD unchanged" \
        "$session_head_before" "$session_head_after"

    # Output must indicate the skip
    local skip_announced
    if echo "$output" | grep -qE "skipping.*session branch|branch name matches session branch"; then
        skip_announced="yes"
    else
        skip_announced="no"
    fi
    assert_eq "test_publish_skips_session_branch_collision: output announces skip for session-branch collision" \
        "yes" "$skip_announced"
}

# ── Test 10: PUBLISH refuses to overwrite pre-existing local branch ──────────
# When a redistribute target branch already exists locally, the tool must
# REFUSE (exit non-zero, error message) rather than silently resetting it.
# This guards against destroying unrelated work that happens to share a name.
test_publish_refuses_preexisting_local_branch() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    # Session branch with one commit (story-a-001 trailer)
    git -C "$repo" checkout -q -b "worktree-session-collide"
    echo "story-file" > "$repo/file-y.sh"
    git -C "$repo" add file-y.sh
    git -C "$repo" commit -q -m "feat: y

DSO-Story: story-a-001"

    # Pre-create the target redistribute branch with a SENTINEL commit
    git -C "$repo" checkout -q main
    git -C "$repo" checkout -q -b "story/epic-y/story-a-001"
    echo "sentinel" > "$repo/sentinel.txt"
    git -C "$repo" add sentinel.txt
    git -C "$repo" commit -q -m "sentinel commit — MUST NOT be destroyed by redistribute"
    local sentinel_sha
    sentinel_sha="$(git -C "$repo" rev-parse HEAD)"
    # Return to session branch
    git -C "$repo" checkout -q "worktree-session-collide"

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-session-collide"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[{"id":"story-a-001","type":"story","title":"S","description":"file-y.sh"}]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    cat > "$mock_scripts/merge-to-main-pr.sh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_scripts/merge-to-main-pr.sh"

    local output exit_code=0
    output=$(PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        DSO_MERGE_TO_MAIN_PR_OVERRIDE="$mock_scripts/merge-to-main-pr.sh" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-y" 2>&1) || exit_code=$?

    # Pre-existing branch HEAD must be unchanged (sentinel commit preserved)
    local target_sha_after
    target_sha_after="$(git -C "$repo" rev-parse "story/epic-y/story-a-001")"
    assert_eq "test_publish_refuses_preexisting_local_branch: target branch HEAD unchanged (sentinel preserved)" \
        "$sentinel_sha" "$target_sha_after"

    # Exit code must be non-zero (refusal)
    local exit_nonzero
    if [[ "$exit_code" -ne 0 ]]; then exit_nonzero="yes"; else exit_nonzero="no"; fi
    assert_eq "test_publish_refuses_preexisting_local_branch: exit code is non-zero" \
        "yes" "$exit_nonzero"

    # Output must explicitly mention the collision
    local error_msg_present
    if echo "$output" | grep -qE "already exists|refusing to overwrite"; then
        error_msg_present="yes"
    else
        error_msg_present="no"
    fi
    assert_eq "test_publish_refuses_preexisting_local_branch: error message mentions collision" \
        "yes" "$error_msg_present"
}

# ── Test 11: cherry-pick failure on one group does not abort remaining groups ─
# When a group's cherry-pick fails (e.g., cross-pollinated dependency), the
# tool must skip that group and CONTINUE to subsequent groups rather than
# exit 2 on the first failure. The partial branch must be cleaned up.
test_publish_continues_past_cherry_pick_failure() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    # Session branch with two stories: story-fail (will conflict) and story-ok (will succeed)
    git -C "$repo" checkout -q -b "worktree-resilient-session"

    # story-ok: single clean commit creating file-ok.sh
    echo "ok-content" > "$repo/file-ok.sh"
    git -C "$repo" add file-ok.sh
    git -C "$repo" commit -q -m "feat: ok

DSO-Story: story-ok-001"

    # story-fail: depends on a file that won't exist on main
    # First create the dependency on a "different story" commit (not in fail's group)
    echo "dep-content" > "$repo/dep-file.sh"
    git -C "$repo" add dep-file.sh
    git -C "$repo" commit -q -m "feat: dep

DSO-Story: story-dep-001"

    # Now story-fail modifies dep-file.sh (will fail when cherry-picked alone onto main)
    echo "fail-content" >> "$repo/dep-file.sh"
    git -C "$repo" add dep-file.sh
    git -C "$repo" commit -q -m "feat: modify dep

DSO-Story: story-fail-001"

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-resilient-session"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    # Scope only mentions file-ok.sh (story-ok) and dep-file.sh (story-fail)
    # story-dep is intentionally NOT in the ticket list — its commit will be UNATTRIBUTED→epoch
    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[
    {"id":"story-ok-001","type":"story","title":"OK","description":"file-ok.sh"},
    {"id":"story-fail-001","type":"story","title":"FAIL","description":"dep-file.sh"}
]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    # Stub merge-to-main-pr.sh: just record the BRANCH it was called for
    local call_log="$tmpdir/merge-calls.log"
    cat > "$mock_scripts/merge-to-main-pr.sh" << MOCKEOF
#!/usr/bin/env bash
echo "called for: \${BRANCH:-\$(git branch --show-current)}" >> "$call_log"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/merge-to-main-pr.sh"

    local exit_code=0
    PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        DSO_MERGE_TO_MAIN_PR_OVERRIDE="$mock_scripts/merge-to-main-pr.sh" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-r" >/dev/null 2>&1 || exit_code=$?

    # Background PRs may still be in flight; wait briefly
    sleep 1

    # story-ok branch must have been published (cherry-pick succeeded → PR opened)
    local ok_called
    if grep -q "story-ok-001" "$call_log" 2>/dev/null; then
        ok_called="yes"
    else
        ok_called="no"
    fi
    assert_eq "test_publish_continues_past_failure: succeeding group's PR was opened" \
        "yes" "$ok_called"
}

# ── Test 12: merge-script invocation is parallel/background ──────────────────
# A slow merge script should not block the next group's publish step.
# Verified by measuring wall time: 3 groups × 2-second slow script should
# complete in ~2 seconds total (parallel), not ~6 seconds (serial).
test_publish_runs_merge_script_in_background() {
    local tmpdir
    tmpdir="$(make_tmpdir)"
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    git -C "$repo" checkout -q -b "worktree-parallel-session"
    # Three independent stories, each one clean commit
    for i in 1 2 3; do
        echo "content-$i" > "$repo/file-$i.sh"
        git -C "$repo" add "file-$i.sh"
        git -C "$repo" commit -q -m "feat: $i

DSO-Story: story-par-00$i"
    done

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-parallel-session"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[
    {"id":"story-par-001","type":"story","title":"P1","description":"file-1.sh"},
    {"id":"story-par-002","type":"story","title":"P2","description":"file-2.sh"},
    {"id":"story-par-003","type":"story","title":"P3","description":"file-3.sh"}
]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    # Slow stub: sleeps 2 seconds before returning
    cat > "$mock_scripts/merge-to-main-pr.sh" << 'MOCKEOF'
#!/usr/bin/env bash
sleep 2
exit 0
MOCKEOF
    chmod +x "$mock_scripts/merge-to-main-pr.sh"

    local start_ts end_ts elapsed
    start_ts="$(date +%s)"
    PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        DSO_MERGE_TO_MAIN_PR_OVERRIDE="$mock_scripts/merge-to-main-pr.sh" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-par" >/dev/null 2>&1 || true
    end_ts="$(date +%s)"
    elapsed=$(( end_ts - start_ts ))

    # Serial execution would be ≥6s (3 × 2s); parallel completes in ~2-3s.
    # Allow generous headroom: <5s is conclusive parallel behavior.
    local is_parallel
    if [[ "$elapsed" -lt 5 ]]; then is_parallel="yes"; else is_parallel="no"; fi
    assert_eq "test_publish_runs_merge_script_in_background: 3×2s stubs complete in <5s (elapsed=${elapsed}s)" \
        "yes" "$is_parallel"

    # Wait for background processes to flush before test teardown
    wait 2>/dev/null || true
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_script_exists
test_dry_run_produces_plan_without_git_mutations
test_empty_range_exits_zero
test_trailer_match_accept_path
test_trailer_mismatch_triggers_split
test_unattributed_falls_back_to_temporal_epochs
test_merge_commits_preserved_not_redistributed
test_dirty_worktree_refused_without_force
test_publish_skips_session_branch_collision
test_publish_refuses_preexisting_local_branch
# ── Test 13: SPLIT phase filters cross-pollinated files per story (bug cf84) ─
# A SPLIT commit's diff must be partitioned by file scope — each story
# branch receives ONLY the files in that commit that match the story's
# declared scope. Observed on epic d076 commits 6def60b4c2 and 964e7a627963
# where bulk-cherry-pick duplicated cross-pollinated files into every matched
# story's branch. (Test function defined here for invocation below.)
test_publish_split_filters_files_per_story() {
    local tmpdir repo
    tmpdir="$(make_tmpdir)"
    repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    # Cross-pollinated commit: trailer says story-a but creates both a.sh + b.sh.
    git -C "$repo" checkout -q -b "worktree-cf84-session"
    echo "a-content" > "$repo/a.sh"
    echo "b-content" > "$repo/b.sh"
    git -C "$repo" add a.sh b.sh
    git -C "$repo" commit -q -m "feat: cross-pollinated

DSO-Story: story-a-001"

    local mock_scripts="$tmpdir/scripts"
    mkdir -p "$mock_scripts"
    cat > "$mock_scripts/resolve-session-branch.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "worktree-cf84-session"
exit 0
MOCKEOF
    chmod +x "$mock_scripts/resolve-session-branch.sh"

    local ticket_json="$tmpdir/tickets.json"
    cat > "$ticket_json" << 'MOCKEOF'
[
    {"id":"story-a-001","type":"story","title":"A","description":"a.sh"},
    {"id":"story-b-001","type":"story","title":"B","description":"b.sh"}
]
MOCKEOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    cat > "$mock_scripts/merge-to-main-pr.sh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_scripts/merge-to-main-pr.sh"

    PATH="$mock_bin:$PATH" \
        DSO_RESOLVE_SESSION_BRANCH="$mock_scripts/resolve-session-branch.sh" \
        DSO_TICKET_LIST_OVERRIDE="$ticket_json" \
        DSO_MERGE_TO_MAIN_PR_OVERRIDE="$mock_scripts/merge-to-main-pr.sh" \
        GIT_DIR="$repo/.git" \
        GIT_WORK_TREE="$repo" \
        bash "$SCRIPT" --epic "epic-cf" >/dev/null 2>&1 || true

    # Wait for background PR-open processes to flush before inspecting branches
    wait 2>/dev/null || true

    # Assertion 1: story-a branch has a.sh, NOT b.sh
    local _files_on_a _a_has_a _a_has_b
    _files_on_a="$(git -C "$repo" ls-tree --name-only "story/epic-cf/story-a-001" 2>/dev/null | sort | tr '\n' ' ')"
    if echo "$_files_on_a" | grep -qw "a.sh"; then _a_has_a="yes"; else _a_has_a="no"; fi
    if echo "$_files_on_a" | grep -qw "b.sh"; then _a_has_b="yes"; else _a_has_b="no"; fi
    assert_eq "test_publish_split_filters_files_per_story: story-a branch HAS a.sh" "yes" "$_a_has_a"
    assert_eq "test_publish_split_filters_files_per_story: story-a branch does NOT have b.sh (cross-pollution filtered out)" "no" "$_a_has_b"

    # Assertion 2: story-b branch has b.sh, NOT a.sh
    local _files_on_b _b_has_a _b_has_b
    _files_on_b="$(git -C "$repo" ls-tree --name-only "story/epic-cf/story-b-001" 2>/dev/null | sort | tr '\n' ' ')"
    if echo "$_files_on_b" | grep -qw "a.sh"; then _b_has_a="yes"; else _b_has_a="no"; fi
    if echo "$_files_on_b" | grep -qw "b.sh"; then _b_has_b="yes"; else _b_has_b="no"; fi
    assert_eq "test_publish_split_filters_files_per_story: story-b branch HAS b.sh" "yes" "$_b_has_b"
    assert_eq "test_publish_split_filters_files_per_story: story-b branch does NOT have a.sh (cross-pollution filtered out)" "no" "$_b_has_a"
}

test_publish_continues_past_cherry_pick_failure
test_publish_runs_merge_script_in_background
test_publish_split_filters_files_per_story

print_summary
