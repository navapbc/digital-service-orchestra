#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-merge-conflict-regression.sh
# Regression tests for bug 50is: merge conflict after review.
#
# BACKGROUND:
#   During the sprint implementing the two-layer review gate (epic gju5), we
#   repeatedly hit a failure pattern (bug 50is):
#     1. Developer makes code changes and gets a valid review
#     2. A git merge main is run, creating conflicts in .tickets/.index.json
#     3. Developer resolves the conflict and stages only .tickets/ files
#     4. The pre-commit hook BLOCKS with "diff hash mismatch" because
#        the review-status diff_hash was stale (computed before the merge)
#   The root cause: only allowlisted files are staged, so the hook SHOULD
#   have exited 0 at the "all staged files are allowlisted" check. The fix
#   ensures the allowlist gate fires BEFORE the hash check.
#
# WHAT THESE TESTS VERIFY:
#   Scenario 1 (primary bug 50is): Review passes on code → merge main →
#     ticket-only conflict → resolve → commit must succeed (all staged files
#     are allowlisted; hook exits 0 before reaching hash check)
#
#   Scenario 2: Review passes on code → merge main → code+ticket conflict →
#     resolve → review required for code files (non-allowlisted files present;
#     hook correctly requires re-review)
#
#   Scenario 3: Multiple sequential merge conflicts (cascading scenario):
#     Code review done → first merge conflict (tickets only) → resolve →
#     commit OK → second merge conflict (tickets only) → resolve → commit OK
#
#   Scenario 4: Stale hash detection: review recorded → only allowlisted files
#     change → the hash goes "stale" (staged is now different allowlisted-only
#     files) → commit should succeed via the allowlist gate (not blocked by
#     stale hash check)
#
# Tests:
#   test_ticket_only_merge_conflict_commit_passes
#   test_code_and_ticket_merge_conflict_requires_review
#   test_multiple_sequential_merge_conflicts_pass
#   test_allowlist_gate_fires_before_stale_hash_check

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/pre-commit-review-gate.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$PLUGIN_ROOT/hooks/lib/deps.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Prerequisite checks ──────────────────────────────────────────────────────
if [[ ! -f "$HOOK" ]]; then
    echo "SKIP: pre-commit-review-gate.sh not found at $HOOK"
    exit 0
fi

if [[ ! -x "$HOOK" ]]; then
    echo "FAIL: pre-commit-review-gate.sh is not executable"
    (( FAIL++ ))
fi

# ── Helper: create a fresh isolated git repo with two branches ───────────────
# Creates a minimal repo with:
#   - main branch: has a code file (mycode.py) and a tickets file
#   - feature branch (checked out): diverges from main, same files modified
# This simulates the state right before a merge conflict occurs.
# Returns the repo directory path on stdout.
make_two_branch_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git -C "$tmpdir" init -b main -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"

    # Create initial commit on main
    mkdir -p "$tmpdir/.tickets"
    cat > "$tmpdir/mycode.py" << 'PYEOF'
def compute(x):
    return x * 2
PYEOF
    cat > "$tmpdir/.tickets/.index.json" << 'JSONEOF'
{"version": 1, "tickets": []}
JSONEOF

    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "init: initial commit"

    # Create a diverging branch for "feature" work
    git -C "$tmpdir" checkout -q -b feature

    # Feature branch: developer makes code changes
    cat > "$tmpdir/mycode.py" << 'PYEOF'
def compute(x):
    return x * 2


def new_feature(y):
    return y + 1
PYEOF
    git -C "$tmpdir" add "mycode.py"
    git -C "$tmpdir" commit -q -m "feat: add new_feature"

    # Go back to main and make a conflicting change to .tickets/.index.json
    git -C "$tmpdir" checkout -q main
    cat > "$tmpdir/.tickets/.index.json" << 'JSONEOF'
{"version": 1, "tickets": ["lockpick-abc1"]}
JSONEOF
    git -C "$tmpdir" add ".tickets/.index.json"
    git -C "$tmpdir" commit -q -m "chore: update ticket index on main"

    # Return to feature branch (the branch the developer is working on)
    git -C "$tmpdir" checkout -q feature

    echo "$tmpdir"
}

# ── Helper: create a fresh artifacts directory ────────────────────────────────
make_artifacts_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    echo "$tmpdir"
}

# ── Helper: run the pre-commit hook in a test repo ────────────────────────────
# Returns exit code on stdout.
run_pre_commit_hook() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
        bash "$HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: run the hook and capture stderr ───────────────────────────────────
run_pre_commit_hook_stderr() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
        bash "$HOOK" 2>&1 >/dev/null
    ) || true
}

# ── Helper: compute the diff hash for staged files in a repo ─────────────────
compute_hash_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
        bash "$PLUGIN_ROOT/hooks/compute-diff-hash.sh" 2>/dev/null
    )
}

# ── Helper: write a valid review-status file ─────────────────────────────────
write_valid_review_status() {
    local artifacts_dir="$1"
    local diff_hash="$2"
    mkdir -p "$artifacts_dir"
    printf 'passed\ntimestamp=2026-03-15T00:00:00Z\ndiff_hash=%s\nscore=5\nreview_hash=abc123\n' \
        "$diff_hash" > "$artifacts_dir/review-status"
}

# ============================================================
# test_ticket_only_merge_conflict_commit_passes
#
# PRIMARY REGRESSION TEST (bug 50is):
# Reproduces the exact failure sequence that caused cascading retry loops:
#
#   1. Developer stages code changes (mycode.py) on feature branch
#   2. A valid review is recorded for that staged diff hash
#   3. git merge main --no-commit creates MERGE_HEAD (merge in progress)
#      The conflict is ONLY in .tickets/.index.json (allowlisted file)
#   4. Developer resolves by accepting the main version of the index
#   5. Developer stages ONLY the resolved .tickets/.index.json
#   6. pre-commit hook runs: ALL staged files are allowlisted (.tickets/)
#      → Should exit 0 WITHOUT checking the (now-stale) diff hash
#
# Before the fix, the hook reached the hash check with the stale review-status
# diff_hash (computed before the merge, when mycode.py was staged). The merge
# changed the working tree but the staged files were now only allowlisted,
# so the hook should never have reached the hash check at all.
# ============================================================
test_ticket_only_merge_conflict_commit_passes() {
    local _repo _artifacts
    _repo=$(make_two_branch_repo)
    _artifacts=$(make_artifacts_dir)

    # Step 1: Stage the code change (developer's work before merge)
    # mycode.py already committed; re-add to simulate staging for review
    git -C "$_repo" add "mycode.py" 2>/dev/null || true

    # Step 2: Record a valid review for the staged code diff
    local diff_hash_at_review
    diff_hash_at_review=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_at_review"

    # Step 3: Commit the code changes (simulates the commit after review)
    # Note: We committed them in make_two_branch_repo; now we simulate
    # a merge scenario where MERGE_HEAD is present with a ticket conflict.
    #
    # Simulate git merge --no-commit (which would be interrupted by conflict):
    # Manually create MERGE_HEAD (pointing to main's HEAD) and stage the
    # conflict resolution of .tickets/.index.json only.
    local main_sha
    main_sha=$(git -C "$_repo" rev-parse main)
    echo "$main_sha" > "$_repo/.git/MERGE_HEAD"

    # Step 4: Resolve the conflict — stage ONLY the ticket index (allowlisted)
    # Write the resolved version of the conflicted file
    cat > "$_repo/.tickets/.index.json" << 'JSONEOF'
{"version": 1, "tickets": ["lockpick-abc1"]}
JSONEOF
    git -C "$_repo" add ".tickets/.index.json"

    # Sanity check: MERGE_HEAD is present (in-progress merge state)
    local merge_head_present=0
    [[ -f "$_repo/.git/MERGE_HEAD" ]] && merge_head_present=1
    assert_eq "test_ticket_only_merge_conflict_commit_passes: MERGE_HEAD present" \
        "1" "$merge_head_present"

    # Sanity check: only .tickets/ files are staged
    local staged_files
    staged_files=$(git -C "$_repo" diff --cached --name-only 2>/dev/null || true)
    assert_contains "test_ticket_only_merge_conflict_commit_passes: only tickets staged" \
        ".tickets/" "$staged_files"

    # Step 5: Run the pre-commit hook
    # Expected: exit 0 — ALL staged files are allowlisted (.tickets/)
    # The hook must fire the allowlist-pass gate BEFORE checking the stale hash
    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_ticket_only_merge_conflict_commit_passes: hook exits 0 (bug 50is regression)" \
        "0" "$exit_code"

    # Cleanup MERGE_HEAD
    rm -f "$_repo/.git/MERGE_HEAD"
}

# ============================================================
# test_code_and_ticket_merge_conflict_requires_review
#
# SCENARIO 2: When the merge conflict affects BOTH code files AND ticket files,
# the developer stages both the resolved code file AND the resolved ticket file.
# Because a non-allowlisted file (mycode.py) is staged, the hook must:
#   - NOT allow without review (the allowlist gate does not fire)
#   - Check for a valid review-status with a matching diff hash
#
# If the review-status diff_hash does NOT match (stale from before merge),
# the hook must block with exit 1, requiring the developer to re-review.
# ============================================================
test_code_and_ticket_merge_conflict_requires_review() {
    local _repo _artifacts
    _repo=$(make_two_branch_repo)
    _artifacts=$(make_artifacts_dir)

    # Step 1: Stage the original code change and record a review for it
    git -C "$_repo" add "mycode.py" 2>/dev/null || true
    local diff_hash_at_review
    diff_hash_at_review=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_at_review"

    # Step 2: Simulate a merge with conflicts in BOTH mycode.py AND .tickets/
    local main_sha
    main_sha=$(git -C "$_repo" rev-parse main)
    echo "$main_sha" > "$_repo/.git/MERGE_HEAD"

    # Step 3: Developer resolves BOTH conflicts:
    # - mycode.py: merge resolution (code changes from both branches)
    cat > "$_repo/mycode.py" << 'PYEOF'
def compute(x):
    return x * 2


def new_feature(y):
    return y + 1


def another_from_main(z):
    return z * 3
PYEOF
    git -C "$_repo" add "mycode.py"

    # - .tickets/.index.json: merge resolution (ticket metadata)
    cat > "$_repo/.tickets/.index.json" << 'JSONEOF'
{"version": 1, "tickets": ["lockpick-abc1", "lockpick-abc2"]}
JSONEOF
    git -C "$_repo" add ".tickets/.index.json"

    # Sanity check: both code and ticket files are staged
    local staged_files
    staged_files=$(git -C "$_repo" diff --cached --name-only 2>/dev/null || true)
    assert_contains "test_code_and_ticket_merge_conflict_requires_review: code staged" \
        "mycode.py" "$staged_files"
    assert_contains "test_code_and_ticket_merge_conflict_requires_review: tickets staged" \
        ".tickets/" "$staged_files"

    # Step 4: Run the hook — should BLOCK because:
    # - mycode.py is staged (non-allowlisted)
    # - The review-status diff_hash is stale (reviewed before code+ticket merge resolution)
    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_code_and_ticket_merge_conflict_requires_review: hook exits 1 (review required for code)" \
        "1" "$exit_code"

    # The error message must mention the code file as requiring review
    local stderr_output
    stderr_output=$(run_pre_commit_hook_stderr "$_repo" "$_artifacts")
    assert_contains "test_code_and_ticket_merge_conflict_requires_review: error names code file" \
        "mycode.py" "$stderr_output"

    # Cleanup MERGE_HEAD
    rm -f "$_repo/.git/MERGE_HEAD"
}

# ============================================================
# test_multiple_sequential_merge_conflicts_pass
#
# SCENARIO 3: The cascading scenario from the bug log.
# Multiple sequential merges (e.g., during /end session) where each merge
# creates a conflict only in .tickets/ files. Each merge+resolve+commit
# sequence must succeed without requiring re-review.
#
# Sequence:
#   review → commit code → merge1 (ticket conflict) → resolve → commit OK
#                        → merge2 (ticket conflict) → resolve → commit OK
# ============================================================
test_multiple_sequential_merge_conflicts_pass() {
    local _repo _artifacts
    _repo=$(make_two_branch_repo)
    _artifacts=$(make_artifacts_dir)

    # Setup: the code is already committed on feature branch.
    # Simulate that a review was recorded earlier (before the merges).
    # The review-status has a diff_hash from when code was staged.
    git -C "$_repo" add "mycode.py" 2>/dev/null || true
    local diff_hash_initial
    diff_hash_initial=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_initial"

    # ── First merge conflict (ticket-only) ────────────────────────────────────
    local main_sha
    main_sha=$(git -C "$_repo" rev-parse main)
    echo "$main_sha" > "$_repo/.git/MERGE_HEAD"

    # Resolve: update .tickets/.index.json (allowlisted)
    cat > "$_repo/.tickets/.index.json" << 'JSONEOF'
{"version": 1, "tickets": ["lockpick-abc1"]}
JSONEOF
    git -C "$_repo" add ".tickets/.index.json"

    # First commit after merge conflict: should pass (ticket-only staged)
    local exit_code_1
    exit_code_1=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_multiple_sequential_merge_conflicts_pass: first merge commit exits 0" \
        "0" "$exit_code_1"

    # Actually commit to advance the branch
    rm -f "$_repo/.git/MERGE_HEAD"
    git -C "$_repo" commit -q -m "merge: resolve first ticket conflict" 2>/dev/null || true

    # ── Second merge conflict (ticket-only again) ─────────────────────────────
    # Simulate another merge from main (another ticket update came in)
    local main_sha_2
    main_sha_2=$(git -C "$_repo" rev-parse main)
    echo "$main_sha_2" > "$_repo/.git/MERGE_HEAD"

    # Resolve: another ticket index update (allowlisted)
    cat > "$_repo/.tickets/.index.json" << 'JSONEOF'
{"version": 1, "tickets": ["lockpick-abc1", "lockpick-abc2"]}
JSONEOF
    git -C "$_repo" add ".tickets/.index.json"

    # Second commit after merge conflict: should also pass (ticket-only staged)
    local exit_code_2
    exit_code_2=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_multiple_sequential_merge_conflicts_pass: second merge commit exits 0" \
        "0" "$exit_code_2"

    # Cleanup MERGE_HEAD
    rm -f "$_repo/.git/MERGE_HEAD"
}

# ============================================================
# test_allowlist_gate_fires_before_stale_hash_check
#
# SCENARIO 4: Stale hash detection — allowlist gate must fire before hash check.
#
# This is the structural test that verifies the gate ordering in the hook:
#   1. Allowlist check (gate A)  ← must be checked FIRST
#   2. Review-status exists check (gate B)
#   3. diff_hash match check (gate C)  ← must be reached ONLY if non-allowlisted files present
#
# If only allowlisted files are staged, gate A must fire (exit 0) even when:
#   - A review-status file EXISTS (with a valid hash)
#   - The review-status diff_hash is STALE (doesn't match current state)
#   - There is a MERGE_HEAD present (in-progress merge)
#
# This is the critical invariant that prevents bug 50is.
# ============================================================
test_allowlist_gate_fires_before_stale_hash_check() {
    local _repo _artifacts
    _repo=$(make_two_branch_repo)
    _artifacts=$(make_artifacts_dir)

    # Setup: write a review-status with a DELIBERATELY STALE hash.
    # This simulates the state after a merge invalidates the diff hash.
    # The stale hash uses the empty-SHA pattern that appeared in bug 50is.
    local stale_hash="e3b0c44298fc1c149afbf4c8996fb92427ae41e4db9defa399b19c9f7e091e3c"
    write_valid_review_status "$_artifacts" "$stale_hash"

    # Create MERGE_HEAD to simulate an in-progress merge
    local main_sha
    main_sha=$(git -C "$_repo" rev-parse main)
    echo "$main_sha" > "$_repo/.git/MERGE_HEAD"

    # Stage ONLY an allowlisted file (the merge conflict resolution for tickets)
    cat > "$_repo/.tickets/.index.json" << 'JSONEOF'
{"version": 1, "tickets": ["lockpick-abc1"]}
JSONEOF
    git -C "$_repo" add ".tickets/.index.json"

    # Sanity check: the stale hash is definitely different from the current hash
    local current_hash
    current_hash=$(compute_hash_in_repo "$_repo" "$_artifacts" || echo "failed_to_compute")
    assert_ne "test_allowlist_gate_fires_before_stale_hash_check: stale hash differs from current" \
        "$stale_hash" "$current_hash"

    # The hook must exit 0 (allowlist gate fires) even though:
    # - MERGE_HEAD is present
    # - review-status has a stale diff_hash
    # - the stale hash != current hash
    # Reason: ALL staged files are allowlisted → gate A fires before gate C
    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_allowlist_gate_fires_before_stale_hash_check: exits 0 (allowlist gate before hash check)" \
        "0" "$exit_code"

    # Cleanup MERGE_HEAD
    rm -f "$_repo/.git/MERGE_HEAD"
}

# ── Run all regression tests ──────────────────────────────────────────────────
test_ticket_only_merge_conflict_commit_passes
test_code_and_ticket_merge_conflict_requires_review
test_multiple_sequential_merge_conflicts_pass
test_allowlist_gate_fires_before_stale_hash_check

print_summary
