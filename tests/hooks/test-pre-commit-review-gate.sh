#!/usr/bin/env bash
# tests/hooks/test-pre-commit-review-gate.sh
# Tests for hooks/pre-commit-review-gate.sh
#
# The pre-commit hook is a git pre-commit hook that:
#   1. Reads staged files via git diff --cached --name-only
#   2. If ALL staged files match the allowlist → allow (exit 0), no review needed
#   3. If any staged file is non-allowlisted → check for valid review-status file
#      with a matching diff hash. Block (exit 1) if no valid review.
#
# Tests:
#   test_allowlisted_only_commit_passes
#   test_tickets_only_commit_passes
#   test_non_allowlisted_without_review_is_blocked
#   test_non_allowlisted_with_valid_review_passes
#   test_merge_head_allowlisted_commit_passes
#   test_blocked_error_message_names_files
#   test_blocked_error_message_directs_to_commit_or_review
#   test_hook_reads_from_shared_allowlist

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-review-gate.sh"
ALLOWLIST="$DSO_PLUGIN_DIR/hooks/lib/review-gate-allowlist.conf"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

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

if [[ ! -f "$ALLOWLIST" ]]; then
    echo "SKIP: review-gate-allowlist.conf not found at $ALLOWLIST"
    exit 0
fi

# ── Helper: create a fresh isolated git repo ─────────────────────────────────
# Creates a minimal git repo with one initial commit.
# Returns the repo directory path on stdout.
# Caller is responsible for cleanup (or register with _TEST_TMPDIRS).
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    echo "initial" > "$tmpdir/README.md"
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Helper: create a fresh artifacts directory ────────────────────────────────
make_artifacts_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    echo "$tmpdir"
}

# ── Helper: run the hook in a test repo ──────────────────────────────────────
# Runs the hook in a subshell with an isolated temp git repo.
# WORKFLOW_PLUGIN_ARTIFACTS_DIR is set to the provided artifacts dir so
# get_artifacts_dir() returns an isolated path (no real state pollution).
#
# Usage: run_hook_in_repo <repo_dir> <artifacts_dir>
# Returns: exit code of the hook on stdout
run_hook_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: capture stderr from the hook ────────────────────────────────────
run_hook_stderr() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$HOOK" 2>&1 >/dev/null
    ) || true
}

# ── Helper: write a valid review-status file ────────────────────────────────
write_valid_review_status() {
    local artifacts_dir="$1"
    local diff_hash="$2"
    mkdir -p "$artifacts_dir"
    printf 'passed\ntimestamp=2026-03-15T00:00:00Z\ndiff_hash=%s\nscore=5\nreview_hash=abc123\n' \
        "$diff_hash" > "$artifacts_dir/review-status"
}

# ── Helper: compute the diff hash for staged files in a repo ────────────────
compute_hash_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null
    )
}

# ============================================================
# test_allowlisted_only_commit_passes
#
# Staging only files that match the allowlist (e.g., .tickets-tracker/) should
# result in exit 0 — no review needed.
# ============================================================
test_allowlisted_only_commit_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage only an allowlisted .tickets-tracker/ file
    mkdir -p "$_repo/.tickets-tracker"
    echo "ticket content" > "$_repo/.tickets-tracker/test-ticket.md"
    git -C "$_repo" add ".tickets-tracker/test-ticket.md"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_allowlisted_only_commit_passes" "0" "$exit_code"
}

# ============================================================
# test_tickets_only_commit_passes
#
# A commit with only .tickets-tracker/ changes passes without a review, per the
# Done Definition. This is the canonical "ticket metadata" exemption.
# ============================================================
test_tickets_only_commit_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    mkdir -p "$_repo/.tickets-tracker"
    echo "# Task: My task" > "$_repo/.tickets-tracker/lockpick-test-abc1.md"
    echo '{"version":1}' > "$_repo/.tickets-tracker/test-abc1/001-create.json"
    git -C "$_repo" add ".tickets-tracker/"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_tickets_only_commit_passes" "0" "$exit_code"
}

# ============================================================
# test_non_allowlisted_without_review_is_blocked
#
# Staging a .py file without a valid review-status file should
# result in exit 1 (blocked).
# ============================================================
test_non_allowlisted_without_review_is_blocked() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a non-allowlisted Python file — no review-status file exists
    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_non_allowlisted_without_review_is_blocked" "1" "$exit_code"
}

# ============================================================
# test_non_allowlisted_with_valid_review_passes
#
# Staging a .py file WITH a valid review-status matching the current
# diff hash should result in exit 0 (allowed).
# ============================================================
test_non_allowlisted_with_valid_review_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a non-allowlisted Python file
    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    # Compute the diff hash so we can write a matching review-status
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_non_allowlisted_with_valid_review_passes" "0" "$exit_code"
}

# ============================================================
# test_merge_head_allowlisted_commit_passes
#
# During an in-progress merge (MERGE_HEAD present), a commit containing
# only allowlisted files should still exit 0.
#
# Simulates MERGE_HEAD by creating the file directly in .git/.
# ============================================================
test_merge_head_allowlisted_commit_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Simulate MERGE_HEAD being present (in-progress merge)
    # Use the current HEAD commit SHA as the MERGE_HEAD value
    local head_sha
    head_sha=$(git -C "$_repo" rev-parse HEAD 2>/dev/null)
    echo "$head_sha" > "$_repo/.git/MERGE_HEAD"

    # Stage an allowlisted tickets file as part of the merge resolution
    mkdir -p "$_repo/.tickets-tracker"
    echo "# Merge resolution note" > "$_repo/.tickets-tracker/merge-note.md"
    git -C "$_repo" add ".tickets-tracker/merge-note.md"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_merge_head_allowlisted_commit_passes" "0" "$exit_code"

    # Cleanup MERGE_HEAD to avoid polluting the test repo state
    rm -f "$_repo/.git/MERGE_HEAD"
}

# ============================================================
# test_blocked_error_message_names_files
#
# When a commit is blocked, the error message must name the specific
# non-allowlisted files that triggered the block.
# ============================================================
test_blocked_error_message_names_files() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a specifically named non-allowlisted file
    echo "print('hello')" > "$_repo/my_feature.py"
    git -C "$_repo" add "my_feature.py"

    local stderr_output
    stderr_output=$(run_hook_stderr "$_repo" "$_artifacts")
    assert_contains "test_blocked_error_message_names_files: names the file" \
        "my_feature.py" "$stderr_output"
}

# ============================================================
# test_blocked_error_message_directs_to_commit_or_review
#
# The error message must direct the user to /commit or /review.
# ============================================================
test_blocked_error_message_directs_to_commit_or_review() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/blocked.py"
    git -C "$_repo" add "blocked.py"

    local stderr_output
    stderr_output=$(run_hook_stderr "$_repo" "$_artifacts")

    # Error message must mention /dso:commit or /dso:review (qualified skill refs)
    local found_directive=0
    if [[ "$stderr_output" == *dso:commit* ]] || [[ "$stderr_output" == *dso:review* ]]; then
        found_directive=1
    fi
    assert_eq "test_blocked_error_message_directs_to_commit_or_review" "1" "$found_directive"
}

# ============================================================
# test_hook_reads_from_shared_allowlist
#
# The hook script must reference review-gate-allowlist.conf — verified
# by grep (the hook must read from the shared allowlist file, not have
# hardcoded patterns).
# ============================================================
test_hook_reads_from_shared_allowlist() {
    local found
    found=$(grep -c 'review-gate-allowlist.conf' "$HOOK" 2>/dev/null || echo "0")
    if [[ "$found" -gt 0 ]]; then
        assert_eq "test_hook_reads_from_shared_allowlist" "true" "true"
    else
        assert_eq "test_hook_reads_from_shared_allowlist" "true" "false"
    fi
}

# ============================================================
# test_formatting_only_drift_self_heals
#
# When review passes and then ruff auto-formatting reformats a staged .py
# file (whitespace/style only), the pre-commit hook should detect that the
# drift is formatting-only, re-compute the hash, update review-status, and
# allow the commit (exit 0) without requiring re-review.
#
# Simulates: review → ruff reformats file → commit attempt
# Expected: self-heal → exit 0
# ============================================================
test_formatting_only_drift_self_heals() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Find ruff binary
    local ruff_bin
    ruff_bin=$(command -v ruff 2>/dev/null || echo "$REPO_ROOT/app/.venv/bin/ruff")
    if [[ ! -x "$ruff_bin" ]]; then
        echo "SKIP: test_formatting_only_drift_self_heals — ruff not available"
        (( PASS++ ))
        return
    fi

    # Commit an initial already-formatted Python file to HEAD so it has a base version
    cat > "$_repo/mymodule.py" << 'PYEOF'
def hello(name):
    return "hello " + name
PYEOF
    git -C "$_repo" add "mymodule.py"
    git -C "$_repo" commit -q -m "add mymodule"

    # Now stage a modification that has ONLY poor formatting (as a developer might write).
    # The logic is the same as HEAD — only whitespace/style changed, no new code.
    # This is what the developer staged and got reviewed — unformatted.
    cat > "$_repo/mymodule.py" << 'PYEOF'
def hello( name ):
    return "hello " + name
PYEOF
    git -C "$_repo" add "mymodule.py"

    # Compute the diff hash in the current (unformatted) state — this simulates
    # the hash captured at review time
    local diff_hash_before
    diff_hash_before=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_before"

    # Simulate ruff reformatting the staged file (like the auto-format pre-commit hook)
    # Run ruff format on the file and re-stage it
    "$ruff_bin" format "$_repo/mymodule.py" 2>/dev/null || true
    git -C "$_repo" add "mymodule.py"

    # At this point: review-status has the old hash, but staged content was ruff-formatted
    # The hash will now differ. The hook should self-heal (formatting-only drift).
    local exit_code
    exit_code=$(
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        export PATH="$(dirname "$ruff_bin"):$PATH"
        bash "$HOOK" 2>/dev/null; echo $?
    )

    assert_eq "test_formatting_only_drift_self_heals: hook exits 0" "0" "$exit_code"
}

# ============================================================
# test_code_change_after_review_blocked
#
# When review passes, then a substantive code change (not just formatting)
# is made to a staged .py file, the pre-commit hook should still block the
# commit (exit 1), even if the change happens to include ruff-formatted code.
#
# Simulates: review → real code change made → commit attempt
# Expected: blocked → exit 1
# ============================================================
test_code_change_after_review_blocked() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Find ruff binary
    local ruff_bin
    ruff_bin=$(command -v ruff 2>/dev/null || echo "$REPO_ROOT/app/.venv/bin/ruff")
    if [[ ! -x "$ruff_bin" ]]; then
        echo "SKIP: test_code_change_after_review_blocked — ruff not available"
        (( PASS++ ))
        return
    fi

    # Commit an initial Python file to HEAD so it has a base version
    cat > "$_repo/feature.py" << 'PYEOF'
def compute(x):
    return x * 2
PYEOF
    git -C "$_repo" add "feature.py"
    git -C "$_repo" commit -q -m "add feature"

    # Stage a modification with the same content (already formatted) — simulate review
    # (developer stages the file in its original reviewed state)
    git -C "$_repo" add "feature.py"

    # Compute the diff hash in the current state — simulate review
    local diff_hash_before
    diff_hash_before=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_before"

    # Now simulate a real code change after review (new function added — not just formatting)
    cat > "$_repo/feature.py" << 'PYEOF'
def compute(x):
    return x * 2


def new_function(y):
    return y + 100
PYEOF
    git -C "$_repo" add "feature.py"

    # At this point: review-status has the old hash, real code was added after review.
    # The hook should NOT self-heal — must block with exit 1.
    local exit_code
    exit_code=$(
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        export PATH="$(dirname "$ruff_bin"):$PATH"
        bash "$HOOK" 2>/dev/null; echo $?
    )

    assert_eq "test_code_change_after_review_blocked: hook exits 1" "1" "$exit_code"
}

# ============================================================
# test_cross_worktree_merge_commit_passes
#
# Cross-worktree scenario: a merge commit in worktree B, where MERGE_HEAD
# exists in worktree B's git dir, and the hook runs in worktree B's context.
# This mirrors the production scenario where Claude Code session in worktree A
# runs `git -C worktree_B commit` — git executes the pre-commit hook in
# worktree B's git context, where MERGE_HEAD is natively visible.
#
# Tests:
#   a) Merge in worktree B with MERGE_HEAD + allowlisted files → passes (exit 0)
#   b) No MERGE_HEAD in worktree B + non-allowlisted file → still blocked (exit 1)
#      (security: no false-positive bypass from external context)
# ============================================================
test_cross_worktree_merge_commit_passes() {
    # ── Scenario A: merge in worktree B, only allowlisted files staged ─────────
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Simulate MERGE_HEAD existing in worktree B's git dir
    # (this is what git writes when `git merge` is in progress in that repo)
    local head_sha
    head_sha=$(git -C "$_repo" rev-parse HEAD 2>/dev/null)
    echo "$head_sha" > "$_repo/.git/MERGE_HEAD"

    # Stage only allowlisted files (merge resolution of ticket event)
    mkdir -p "$_repo/.tickets-tracker/test-abc1"
    echo '{"version":2}' > "$_repo/.tickets-tracker/test-abc1/001-create.json"
    git -C "$_repo" add ".tickets-tracker/test-abc1/001-create.json"

    # Hook runs in worktree B's context — MERGE_HEAD is natively visible
    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_cross_worktree_merge_commit_passes: merge+allowlisted passes" "0" "$exit_code"

    # Cleanup
    rm -f "$_repo/.git/MERGE_HEAD"

    # ── Scenario B: no MERGE_HEAD, non-allowlisted file, no review → blocked ───
    # Security check: a commit targeting a different dir (no MERGE_HEAD) must
    # NOT bypass the review gate — the hook checks git state, not caller context.
    local _repo2 _artifacts2
    _repo2=$(make_test_repo)
    _artifacts2=$(make_artifacts_dir)

    # No MERGE_HEAD set — normal commit scenario from an external session
    echo "print('cross worktree code')" > "$_repo2/cross_worktree.py"
    git -C "$_repo2" add "cross_worktree.py"

    local exit_code2
    exit_code2=$(run_hook_in_repo "$_repo2" "$_artifacts2")
    assert_eq "test_cross_worktree_merge_commit_passes: no-MERGE_HEAD non-allowlisted blocked" "1" "$exit_code2"
}

# ============================================================
# test_merge_head_with_non_allowlisted_and_valid_review_passes
#
# During a merge commit with MERGE_HEAD, if non-allowlisted files are staged
# as part of the merge resolution and a valid review exists for them, the
# hook should pass (exit 0). The MERGE_HEAD alone does not bypass the review
# requirement — only allowlisted files bypass it.
# ============================================================
test_merge_head_with_non_allowlisted_and_valid_review_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Simulate MERGE_HEAD (in-progress merge)
    local head_sha
    head_sha=$(git -C "$_repo" rev-parse HEAD 2>/dev/null)
    echo "$head_sha" > "$_repo/.git/MERGE_HEAD"

    # Stage a non-allowlisted file as part of merge resolution
    echo "print('merged code')" > "$_repo/merged_module.py"
    git -C "$_repo" add "merged_module.py"

    # Compute hash and write valid review-status
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_merge_head_with_non_allowlisted_and_valid_review_passes" "0" "$exit_code"

    # Cleanup
    rm -f "$_repo/.git/MERGE_HEAD"
}

# ============================================================
# test_merge_commit_with_incoming_non_allowlisted_passes
#
# Bug: w21-0oc6, dso-k7fe
# When merging main into a worktree (git merge origin/main), the merge
# commit includes files changed on main since the branch point. These
# incoming-only files appear in `git diff --cached` but were already
# reviewed and merged on main. The review gate should NOT require review
# for files that only changed on the incoming branch.
#
# Scenario:
#   1. Create a repo with an initial commit
#   2. Create a "worktree" branch from main
#   3. On main: add a non-allowlisted .py file and commit
#   4. On the worktree branch: add only an allowlisted file
#   5. Merge main into the worktree branch
#   6. The merge commit includes the .py file from main (incoming)
#   7. The hook should pass (exit 0) — the .py file is incoming-only
#
# Expected: exit 0 (no review needed for incoming-only files)
# ============================================================
test_merge_commit_with_incoming_non_allowlisted_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a branch for the "worktree"
    git -C "$_repo" checkout -q -b worktree-branch

    # Switch back to main and add a non-allowlisted .py file
    git -C "$_repo" checkout -q main 2>/dev/null || git -C "$_repo" checkout -q master
    echo "print('from main')" > "$_repo/main_feature.py"
    git -C "$_repo" add "main_feature.py"
    git -C "$_repo" commit -q -m "add feature on main"

    # Switch to the worktree branch — no .py files here
    git -C "$_repo" checkout -q worktree-branch

    # Add only an allowlisted file on the worktree branch
    mkdir -p "$_repo/.tickets-tracker"
    echo "ticket" > "$_repo/.tickets-tracker/wt-001.md"
    git -C "$_repo" add ".tickets-tracker/wt-001.md"
    git -C "$_repo" commit -q -m "add ticket on worktree"

    # Merge main into the worktree branch (this brings in main_feature.py)
    git -C "$_repo" merge --no-edit main 2>/dev/null || git -C "$_repo" merge --no-edit master 2>/dev/null

    # At this point there's no MERGE_HEAD (merge completed cleanly).
    # Let's simulate the actual bug scenario: a merge that results in a commit
    # where MERGE_HEAD is still present (merge in progress, about to commit).
    # We need to set up a conflict scenario or simulate MERGE_HEAD.

    # Reset to before the merge
    git -C "$_repo" reset --hard HEAD~1 2>/dev/null

    # Start a merge that we'll commit via the hook
    # First, create a conflict-free merge scenario with MERGE_HEAD
    git -C "$_repo" merge --no-commit main 2>/dev/null || git -C "$_repo" merge --no-commit master 2>/dev/null || true

    # MERGE_HEAD should now exist
    if [[ ! -f "$_repo/.git/MERGE_HEAD" ]]; then
        echo "SKIP: test_merge_commit_with_incoming_non_allowlisted_passes — could not create MERGE_HEAD"
        (( PASS++ ))
        return
    fi

    # git diff --cached now shows main_feature.py as staged (from incoming main)
    # The hook should recognize this is an incoming-only file and pass without review
    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_merge_commit_with_incoming_non_allowlisted_passes" "0" "$exit_code"
}

# ============================================================
# test_fake_merge_head_does_not_bypass_review
#
# Bug: w21-0oc6, dso-k7fe (security complement)
# A manually created MERGE_HEAD with an invalid SHA should NOT bypass
# review for non-allowlisted staged files. The merge-base computation
# must fail gracefully and fall back to normal review enforcement.
#
# Scenario:
#   1. Stage a non-allowlisted .py file (normal commit, no merge)
#   2. Create a fake MERGE_HEAD with an invalid SHA
#   3. The hook should still block (no valid merge base → normal flow)
#
# Expected: exit 1 (blocked — fake MERGE_HEAD doesn't bypass review)
# ============================================================
test_fake_merge_head_does_not_bypass_review() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a non-allowlisted Python file — no review exists
    echo "print('sneaky')" > "$_repo/sneaky.py"
    git -C "$_repo" add "sneaky.py"

    # Create a fake MERGE_HEAD with an invalid SHA
    echo "0000000000000000000000000000000000000000" > "$_repo/.git/MERGE_HEAD"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_fake_merge_head_does_not_bypass_review" "1" "$exit_code"

    # Cleanup
    rm -f "$_repo/.git/MERGE_HEAD"
}

# ============================================================
# test_review_gate_rebase_filters_incoming_only
#
# During a rebase (REBASE_HEAD + rebase-merge/onto + rebase-merge/orig-head
# present), files that only changed on the onto branch (incoming-only) should
# be filtered from review enforcement. The hook should exit 0.
#
# Setup:
#   1. Create a worktree branch from main with one commit
#   2. On main, add a non-allowlisted .py file (onto-branch-only change)
#   3. Simulate mid-rebase state: write .git/REBASE_HEAD, .git/rebase-merge/onto,
#      and .git/rebase-merge/orig-head (NOT .git/ORIG_HEAD)
#   4. Stage the onto-branch-only .py file
#
# Expected: exit 0 (incoming-only file filtered, nothing to review)
#
# RED: No REBASE_HEAD handling exists in pre-commit-review-gate.sh.
# Without filtering, the hook sees a staged non-allowlisted .py file with no
# review-status and blocks (exit 1). This test fails until the feature lands.
# ============================================================
test_review_gate_rebase_filters_incoming_only() {
    local _repo _artifacts
    _repo=$(mktemp -d)
    _TEST_TMPDIRS+=("$_repo")
    _artifacts=$(make_artifacts_dir)

    # Initialize repo with an initial commit on main
    git -C "$_repo" init -q
    git -C "$_repo" config user.email "test@test.com"
    git -C "$_repo" config user.name "Test"
    git -C "$_repo" config commit.gpgsign false

    echo "initial" > "$_repo/README.md"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "initial commit"

    local _main_branch
    _main_branch=$(git -C "$_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

    # Create a worktree branch with a divergent commit (no .py changes here)
    git -C "$_repo" checkout -q -b worktree-branch
    echo "worktree change" >> "$_repo/README.md"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "worktree commit"

    local _orig_head_sha
    _orig_head_sha=$(git -C "$_repo" rev-parse HEAD 2>/dev/null)

    # Switch back to main and add a non-allowlisted .py file (onto-branch-only)
    git -C "$_repo" checkout -q "$_main_branch"
    echo "def rebase_incoming(): pass" > "$_repo/rebase_incoming.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add rebase_incoming.py on main (onto branch)"

    local _onto_sha
    _onto_sha=$(git -C "$_repo" rev-parse HEAD 2>/dev/null)

    # Switch to worktree branch and simulate mid-rebase state
    git -C "$_repo" checkout -q worktree-branch

    mkdir -p "$_repo/.git/rebase-merge"
    echo "$_onto_sha" > "$_repo/.git/rebase-merge/onto"
    echo "$_orig_head_sha" > "$_repo/.git/rebase-merge/orig-head"
    echo "$_orig_head_sha" > "$_repo/.git/REBASE_HEAD"

    # Stage the onto-branch-only .py file (incoming-only during rebase)
    git -C "$_repo" checkout -q "$_onto_sha" -- rebase_incoming.py 2>/dev/null || true
    git -C "$_repo" add rebase_incoming.py 2>/dev/null || true

    if [[ ! -f "$_repo/.git/REBASE_HEAD" ]]; then
        assert_eq "test_review_gate_rebase_filters_incoming_only: REBASE_HEAD created" \
            "present" "absent"
        return
    fi

    # RED assertion: REBASE_HEAD filtering logic is absent from the hook.
    # When this fires, the test records a RED failure explaining the gap.
    if ! grep -q 'REBASE_HEAD\|rebase-merge' "$HOOK" 2>/dev/null; then
        assert_eq "test_review_gate_rebase_filters_incoming_only: rebase filtering absent (RED)" \
            "rebase_filtering_present" "rebase_filtering_absent"
        return
    fi

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_review_gate_rebase_filters_incoming_only: hook exits 0 for incoming-only file" \
        "0" "$exit_code"
}

# ============================================================
# test_review_gate_rebase_keeps_worktree_files
#
# During a rebase, a file that was also modified on the worktree branch
# must NOT be filtered. The hook should enforce review normally (exit non-zero)
# when the staged file also appears in the worktree-branch diff.
#
# Setup:
#   1. Create a file on initial commit (shared_rebase_rv.py)
#   2. Worktree branch modifies it; onto branch also modifies it
#   3. Simulate rebase state; stage the version from the onto branch
#
# Expected: exit non-zero (file is in worktree diff — not incoming-only)
#
# RED: Without REBASE_HEAD handling, the hook already sees this staged
# non-allowlisted file and blocks (exit 1) — but for the wrong reason
# (no REBASE_HEAD detection at all). This test remains RED until the
# feature is implemented, at which point it guards correct behavior.
# ============================================================
test_review_gate_rebase_keeps_worktree_files() {
    local _repo _artifacts
    _repo=$(mktemp -d)
    _TEST_TMPDIRS+=("$_repo")
    _artifacts=$(make_artifacts_dir)

    git -C "$_repo" init -q
    git -C "$_repo" config user.email "test@test.com"
    git -C "$_repo" config user.name "Test"
    git -C "$_repo" config commit.gpgsign false

    # Initial commit with a shared source file
    echo "def shared_rebase_rv(): return 1" > "$_repo/shared_rebase_rv.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "initial commit"

    local _main_branch
    _main_branch=$(git -C "$_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

    # Worktree branch modifies the shared file
    git -C "$_repo" checkout -q -b worktree-branch
    echo "# worktree change" >> "$_repo/shared_rebase_rv.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "worktree modifies shared_rebase_rv.py"

    local _orig_head_sha
    _orig_head_sha=$(git -C "$_repo" rev-parse HEAD 2>/dev/null)

    # Onto branch (main) also modifies the shared file
    git -C "$_repo" checkout -q "$_main_branch"
    echo "# onto change" >> "$_repo/shared_rebase_rv.py"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "main also modifies shared_rebase_rv.py"

    local _onto_sha
    _onto_sha=$(git -C "$_repo" rev-parse HEAD 2>/dev/null)

    # Switch to worktree branch and simulate mid-rebase state
    git -C "$_repo" checkout -q worktree-branch

    mkdir -p "$_repo/.git/rebase-merge"
    echo "$_onto_sha" > "$_repo/.git/rebase-merge/onto"
    echo "$_orig_head_sha" > "$_repo/.git/rebase-merge/orig-head"
    echo "$_orig_head_sha" > "$_repo/.git/REBASE_HEAD"

    # Stage the shared file (modified on both branches — not incoming-only)
    git -C "$_repo" checkout -q "$_onto_sha" -- shared_rebase_rv.py 2>/dev/null || true
    git -C "$_repo" add shared_rebase_rv.py 2>/dev/null || true

    if [[ ! -f "$_repo/.git/REBASE_HEAD" ]]; then
        assert_eq "test_review_gate_rebase_keeps_worktree_files: REBASE_HEAD created" \
            "present" "absent"
        return
    fi

    # RED assertion: REBASE_HEAD filtering logic is absent from the hook.
    if ! grep -q 'REBASE_HEAD\|rebase-merge' "$HOOK" 2>/dev/null; then
        assert_eq "test_review_gate_rebase_keeps_worktree_files: rebase filtering absent (RED)" \
            "rebase_filtering_present" "rebase_filtering_absent"
        return
    fi

    # Once rebase filtering is implemented, gate must still block for the
    # worktree-modified file (no review-status exists for it)
    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_ne "test_review_gate_rebase_keeps_worktree_files: hook blocks for worktree-modified file during rebase" \
        "0" "$exit_code"
}

# ============================================================
# test_review_gate_rebase_failsafe_missing_onto
#
# When REBASE_HEAD is present but rebase-merge/onto is absent
# (incomplete or unusual rebase state), the hook must fall through
# to normal review enforcement rather than silently allowing the commit.
#
# Setup:
#   1. Stage a non-allowlisted .py file
#   2. Write .git/REBASE_HEAD but omit .git/rebase-merge/onto entirely
#
# Expected: exit non-zero (fallback to normal enforcement; no review → blocked)
#
# RED: No REBASE_HEAD handling exists in pre-commit-review-gate.sh.
# This test asserts that once handling is added, the failsafe path holds.
# ============================================================
test_review_gate_rebase_failsafe_missing_onto() {
    local _repo _artifacts
    _repo=$(mktemp -d)
    _TEST_TMPDIRS+=("$_repo")
    _artifacts=$(make_artifacts_dir)

    git -C "$_repo" init -q
    git -C "$_repo" config user.email "test@test.com"
    git -C "$_repo" config user.name "Test"
    git -C "$_repo" config commit.gpgsign false

    echo "initial" > "$_repo/README.md"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "initial commit"

    # Stage a non-allowlisted Python file (no review-status exists)
    echo "def failsafe_test(): pass" > "$_repo/failsafe_rebase_rv.py"
    git -C "$_repo" add failsafe_rebase_rv.py

    # Write REBASE_HEAD but deliberately omit rebase-merge/onto
    echo "$(git -C "$_repo" rev-parse HEAD 2>/dev/null)" > "$_repo/.git/REBASE_HEAD"
    # Intentionally do NOT create .git/rebase-merge/ or .git/rebase-merge/onto

    if [[ ! -f "$HOOK" ]]; then
        assert_eq "test_review_gate_rebase_failsafe_missing_onto: hook not found (RED)" "missing" "missing"
        return
    fi

    # RED assertion: REBASE_HEAD filtering logic is absent from the hook.
    if ! grep -q 'REBASE_HEAD\|rebase-merge' "$HOOK" 2>/dev/null; then
        assert_eq "test_review_gate_rebase_failsafe_missing_onto: rebase filtering absent (RED)" \
            "rebase_filtering_present" "rebase_filtering_absent"
        rm -f "$_repo/.git/REBASE_HEAD"
        return
    fi

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")

    rm -f "$_repo/.git/REBASE_HEAD"

    # Fallback must block: missing onto → no filtering → normal enforcement → blocked
    assert_ne "test_review_gate_rebase_failsafe_missing_onto: hook blocks when onto missing (failsafe)" \
        "0" "$exit_code"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_allowlisted_only_commit_passes
test_tickets_only_commit_passes
test_non_allowlisted_without_review_is_blocked
test_non_allowlisted_with_valid_review_passes
test_merge_head_allowlisted_commit_passes
test_blocked_error_message_names_files
test_blocked_error_message_directs_to_commit_or_review
test_hook_reads_from_shared_allowlist
test_formatting_only_drift_self_heals
test_code_change_after_review_blocked
test_cross_worktree_merge_commit_passes
test_merge_head_with_non_allowlisted_and_valid_review_passes
test_merge_commit_with_incoming_non_allowlisted_passes
test_fake_merge_head_does_not_bypass_review
test_review_gate_rebase_filters_incoming_only
test_review_gate_rebase_keeps_worktree_files
test_review_gate_rebase_failsafe_missing_onto

print_summary
