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
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
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
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
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
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
        bash "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null
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
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
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
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
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

    # Stage only allowlisted files (merge resolution of ticket index)
    mkdir -p "$_repo/.tickets"
    echo '{"version":2}' > "$_repo/.tickets/.index.json"
    git -C "$_repo" add ".tickets/.index.json"

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

print_summary
