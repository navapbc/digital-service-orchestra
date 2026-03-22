#!/usr/bin/env bash
# tests/hooks/test-reviewer-fragment-staleness.sh
# Tests for commit-time source-fragment staleness enforcement in
# pre-commit-review-gate.sh.
#
# When a reviewer source fragment (reviewer-base.md or reviewer-delta-*.md)
# is staged for commit, the pre-commit hook should verify that the
# corresponding generated agent files have up-to-date content hashes.
# If hashes are stale (fragment changed but generated agent not rebuilt),
# the commit is blocked until build-review-agents.sh is re-run.
#
# Tests:
#   test_staleness_check_blocks_commit_when_base_staged_and_hash_stale
#   test_staleness_check_blocks_commit_when_delta_staged_and_hash_stale
#   test_staleness_check_allows_commit_when_fragments_staged_and_hashes_current
#   test_staleness_check_skipped_when_no_fragments_staged
#   test_staleness_check_provides_regeneration_guidance

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

if [[ ! -f "$ALLOWLIST" ]]; then
    echo "SKIP: review-gate-allowlist.conf not found at $ALLOWLIST"
    exit 0
fi

# ── Helper: create a fresh isolated git repo ─────────────────────────────────
# Creates a minimal git repo with one initial commit.
# Returns the repo directory path on stdout.
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

# ── Helper: set up a repo with fragment structure ────────────────────────────
# Creates the reviewer source fragment directory structure and a fake
# generated agent file. Returns the repo dir.
# Usage: setup_fragment_repo
# Sets globals: _FRAG_REPO, _FRAG_ARTIFACTS
setup_fragment_repo() {
    _FRAG_REPO=$(make_test_repo)
    _FRAG_ARTIFACTS=$(make_artifacts_dir)

    # Create the source fragment directory structure
    mkdir -p "$_FRAG_REPO/plugins/dso/docs/workflows/prompts"
    # Create a generated agents directory
    mkdir -p "$_FRAG_REPO/plugins/dso/agents"

    # Create initial reviewer-base.md and reviewer-delta-light.md, then commit
    echo "# Base reviewer guidance v1" > "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-base.md"
    echo "# Delta: light tier v1" > "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-delta-light.md"
    git -C "$_FRAG_REPO" add -A
    git -C "$_FRAG_REPO" commit -q -m "add initial fragments"

    # Create a generated agent file with content-hash matching v1
    # Hash algorithm: sha256(base_content + "\n" + delta_content) — same as build-review-agents.sh
    local base_content delta_content content_hash
    base_content=$(cat "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-base.md")
    delta_content=$(cat "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-delta-light.md")
    content_hash=$(printf '%s\n%s' "$base_content" "$delta_content" | shasum -a 256 | cut -d' ' -f1)
    cat > "$_FRAG_REPO/plugins/dso/agents/code-reviewer-light.md" <<AGENT
---
name: code-reviewer-light
model: haiku
tools: [Bash, Read, Glob, Grep]
description: Light-tier code reviewer
---
<!-- content-hash: ${content_hash} -->
<!-- generated by build-review-agents.sh — do not edit manually -->

${base_content}

${delta_content}
AGENT
    git -C "$_FRAG_REPO" add -A
    git -C "$_FRAG_REPO" commit -q -m "add generated agent"
}

# ============================================================
# test_staleness_check_blocks_commit_when_base_staged_and_hash_stale
#
# When reviewer-base.md is modified and staged, but the generated agent
# file still has the old content hash, the commit should be blocked
# (exit non-zero) because the agent is stale.
#
# This test is RED: the staleness check is not yet implemented in
# pre-commit-review-gate.sh, so the hook will not detect stale hashes
# and will exit 0 (or block for a different reason). The test expects
# exit non-zero specifically due to staleness.
# ============================================================
test_staleness_check_blocks_commit_when_base_staged_and_hash_stale() {
    setup_fragment_repo

    # Modify reviewer-base.md (the source fragment) — this changes the hash
    echo "# Base reviewer guidance v2 — updated" > "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-base.md"
    git -C "$_FRAG_REPO" add "plugins/dso/docs/workflows/prompts/reviewer-base.md"

    # The generated agent still has the old hash from v1 — it is STALE
    # Stage the generated agent too (unchanged) so the commit has both
    # Do NOT update the hash in the generated agent — that's the staleness

    # Provide a valid review-status so the review gate itself does not block
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_FRAG_REPO" "$_FRAG_ARTIFACTS")
    write_valid_review_status "$_FRAG_ARTIFACTS" "$diff_hash"

    local exit_code
    exit_code=$(run_hook_in_repo "$_FRAG_REPO" "$_FRAG_ARTIFACTS")

    # Expected: non-zero (blocked due to stale hash)
    # RED: currently the hook does not check staleness, so this will exit 0
    assert_ne "test_staleness_check_blocks_commit_when_base_staged_and_hash_stale: should block" \
        "0" "$exit_code"
}

# ============================================================
# test_staleness_check_blocks_commit_when_delta_staged_and_hash_stale
#
# When a reviewer-delta-*.md file is modified and staged, but the
# generated agent has the old content hash, the commit should be blocked.
#
# RED: staleness check not implemented yet.
# ============================================================
test_staleness_check_blocks_commit_when_delta_staged_and_hash_stale() {
    setup_fragment_repo

    # Modify the delta file — content-hash in agent becomes stale
    echo "# Delta: light tier v2 — updated criteria" > "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-delta-light.md"
    git -C "$_FRAG_REPO" add "plugins/dso/docs/workflows/prompts/reviewer-delta-light.md"

    # Generated agent still has old content-hash from v1 — STALE

    # Provide valid review-status
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_FRAG_REPO" "$_FRAG_ARTIFACTS")
    write_valid_review_status "$_FRAG_ARTIFACTS" "$diff_hash"

    local exit_code
    exit_code=$(run_hook_in_repo "$_FRAG_REPO" "$_FRAG_ARTIFACTS")

    # Expected: non-zero (blocked due to stale delta hash)
    assert_ne "test_staleness_check_blocks_commit_when_delta_staged_and_hash_stale: should block" \
        "0" "$exit_code"
}

# ============================================================
# test_staleness_check_allows_commit_when_fragments_staged_and_hashes_current
#
# When a source fragment is staged AND the generated agent is also staged
# with a matching (current) content hash, the commit should be allowed.
#
# RED: the staleness check mechanism does not exist yet, but this test
# validates the "allow" path. Since the hook currently ignores fragments
# entirely, this test may pass incidentally (the hook allows it for other
# reasons). We assert exit 0 regardless — the test validates the contract.
# ============================================================
test_staleness_check_allows_commit_when_fragments_staged_and_hashes_current() {
    setup_fragment_repo

    # Modify reviewer-base.md
    echo "# Base reviewer guidance v2 — updated" > "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-base.md"

    # Recompute content-hash for the updated base + existing delta (same algorithm as build-review-agents.sh)
    local new_base_content delta_content new_content_hash
    new_base_content=$(cat "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-base.md")
    delta_content=$(cat "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-delta-light.md")
    new_content_hash=$(printf '%s\n%s' "$new_base_content" "$delta_content" | shasum -a 256 | cut -d' ' -f1)

    # Update the generated agent with the NEW hash (simulating build-review-agents.sh was run)
    cat > "$_FRAG_REPO/plugins/dso/agents/code-reviewer-light.md" <<AGENT
---
name: code-reviewer-light
model: haiku
tools: [Bash, Read, Glob, Grep]
description: Light-tier code reviewer
---
<!-- content-hash: ${new_content_hash} -->
<!-- generated by build-review-agents.sh — do not edit manually -->

${new_base_content}

${delta_content}
AGENT

    # Stage both the fragment and the updated generated agent
    git -C "$_FRAG_REPO" add "plugins/dso/docs/workflows/prompts/reviewer-base.md"
    git -C "$_FRAG_REPO" add "plugins/dso/agents/code-reviewer-light.md"

    # Provide valid review-status
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_FRAG_REPO" "$_FRAG_ARTIFACTS")
    write_valid_review_status "$_FRAG_ARTIFACTS" "$diff_hash"

    local exit_code
    exit_code=$(run_hook_in_repo "$_FRAG_REPO" "$_FRAG_ARTIFACTS")

    # Expected: exit 0 (allowed — hashes are current)
    assert_eq "test_staleness_check_allows_commit_when_fragments_staged_and_hashes_current: should allow" \
        "0" "$exit_code"
}

# ============================================================
# test_staleness_check_skipped_when_no_fragments_staged
#
# When no reviewer source fragments are staged, the staleness check
# should not fire at all. A normal commit of a .py file with valid
# review should pass.
#
# This test validates the "no fragments" bypass path. Since the staleness
# check is not implemented yet, the hook behaves normally — this test
# should pass (GREEN) even before implementation.
# ============================================================
test_staleness_check_skipped_when_no_fragments_staged() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a normal Python file (no fragments involved)
    echo "print('no fragments here')" > "$_repo/app.py"
    git -C "$_repo" add "app.py"

    # Provide valid review-status
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")

    # Expected: exit 0 (staleness check skipped, normal review passes)
    assert_eq "test_staleness_check_skipped_when_no_fragments_staged: should allow" \
        "0" "$exit_code"
}

# ============================================================
# test_staleness_check_provides_regeneration_guidance
#
# When a commit is blocked due to stale fragment hashes, the error
# message should reference build-review-agents.sh so the developer
# knows how to fix it.
#
# RED: staleness check not implemented yet, so no staleness-specific
# error message is produced.
# ============================================================
test_staleness_check_provides_regeneration_guidance() {
    setup_fragment_repo

    # Modify reviewer-base.md to create staleness
    echo "# Base reviewer guidance v3 — changed again" > "$_FRAG_REPO/plugins/dso/docs/workflows/prompts/reviewer-base.md"
    git -C "$_FRAG_REPO" add "plugins/dso/docs/workflows/prompts/reviewer-base.md"

    # Provide valid review-status so review gate does not interfere
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_FRAG_REPO" "$_FRAG_ARTIFACTS")
    write_valid_review_status "$_FRAG_ARTIFACTS" "$diff_hash"

    local stderr_output
    stderr_output=$(run_hook_stderr "$_FRAG_REPO" "$_FRAG_ARTIFACTS")

    # Expected: error message mentions build-review-agents.sh
    # RED: no staleness error is emitted yet
    assert_contains "test_staleness_check_provides_regeneration_guidance: mentions build script" \
        "build-review-agents.sh" "$stderr_output"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_staleness_check_blocks_commit_when_base_staged_and_hash_stale
test_staleness_check_blocks_commit_when_delta_staged_and_hash_stale
test_staleness_check_allows_commit_when_fragments_staged_and_hashes_current
test_staleness_check_skipped_when_no_fragments_staged
test_staleness_check_provides_regeneration_guidance

print_summary
