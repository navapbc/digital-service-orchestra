#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-pre-commit-review-gate.sh
# Tests for lockpick-workflow/hooks/pre-commit-review-gate.sh
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

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/pre-commit-review-gate.sh"
ALLOWLIST="$REPO_ROOT/lockpick-workflow/hooks/lib/review-gate-allowlist.conf"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

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
        export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
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
        export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
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
        export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
        bash "$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh" 2>/dev/null
    )
}

# ============================================================
# test_allowlisted_only_commit_passes
#
# Staging only files that match the allowlist (e.g., .tickets/) should
# result in exit 0 — no review needed.
# ============================================================
test_allowlisted_only_commit_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage only an allowlisted .tickets/ file
    mkdir -p "$_repo/.tickets"
    echo "ticket content" > "$_repo/.tickets/test-ticket.md"
    git -C "$_repo" add ".tickets/test-ticket.md"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_allowlisted_only_commit_passes" "0" "$exit_code"
}

# ============================================================
# test_tickets_only_commit_passes
#
# A commit with only .tickets/ changes passes without a review, per the
# Done Definition. This is the canonical "ticket metadata" exemption.
# ============================================================
test_tickets_only_commit_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    mkdir -p "$_repo/.tickets"
    echo "# Task: My task" > "$_repo/.tickets/lockpick-test-abc1.md"
    echo '{"version":1}' > "$_repo/.tickets/.index.json"
    git -C "$_repo" add ".tickets/"

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
    mkdir -p "$_repo/.tickets"
    echo "# Merge resolution note" > "$_repo/.tickets/merge-note.md"
    git -C "$_repo" add ".tickets/merge-note.md"

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

    # Error message must mention /commit or /review
    local found_directive=0
    if [[ "$stderr_output" == */commit* ]] || [[ "$stderr_output" == */review* ]]; then
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

# ── Run all tests ────────────────────────────────────────────────────────────
test_allowlisted_only_commit_passes
test_tickets_only_commit_passes
test_non_allowlisted_without_review_is_blocked
test_non_allowlisted_with_valid_review_passes
test_merge_head_allowlisted_commit_passes
test_blocked_error_message_names_files
test_blocked_error_message_directs_to_commit_or_review
test_hook_reads_from_shared_allowlist

print_summary
