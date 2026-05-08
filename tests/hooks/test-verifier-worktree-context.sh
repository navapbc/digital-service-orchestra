#!/usr/bin/env bash
# tests/hooks/test-verifier-worktree-context.sh
# RED tests for task 536c-cd2a-13f7-4074: verifier in sub-agent harvested worktree context.
#
# Tests that pre-commit-compliance-verifier.sh reads from WORKFLOW_PLUGIN_ARTIFACTS_DIR
# (the caller-supplied override), not from a hardcoded or default-computed path.
# This ensures sub-agents running inside worktrees point the verifier at the correct
# isolated artifacts directory rather than the main repo's shared artifacts dir.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/plugins/dso/hooks/pre-commit-compliance-verifier.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

_TEST_TMPDIRS=()
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: create an artifacts dir with all 5 required step results present
# ---------------------------------------------------------------------------
make_full_artifacts_dir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-wt-XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "pass" > "$d/test.result"
    echo "pass" > "$d/format.result"
    echo "pass" > "$d/lint.result"
    echo "pass" > "$d/classifier-dispatch.result"
    echo "pass" > "$d/reviewer-record.result"
    echo "$d"
}

# ---------------------------------------------------------------------------
# Helper: create an empty (no artifacts) dir
# ---------------------------------------------------------------------------
make_empty_artifacts_dir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-empty-XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ---------------------------------------------------------------------------
# Helper: run hook with WORKFLOW_PLUGIN_ARTIFACTS_DIR override, return exit code
# ---------------------------------------------------------------------------
run_hook_with_dir() {
    local artifacts_dir="$1"
    local exit_code=0
    env \
        "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
        "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$artifacts_dir" \
        bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ---------------------------------------------------------------------------
# test_verifier_reads_correct_worktree
#
# Scenario: two dirs exist — a "main repo" dir with all 5 artifacts, and a
# "worktree" dir with no artifacts.
#
# - When WORKFLOW_PLUGIN_ARTIFACTS_DIR points to the full dir → exits 0
#   (verifier reads from the correct dir and sees all artifacts).
# - When WORKFLOW_PLUGIN_ARTIFACTS_DIR points to the empty dir → exits 1
#   (verifier reads from the override dir and correctly finds nothing).
#
# This asserts that the verifier uses WORKFLOW_PLUGIN_ARTIFACTS_DIR exclusively,
# not any hardcoded or git-derived fallback path.
# ---------------------------------------------------------------------------
MAIN_ARTIFACTS=$(make_full_artifacts_dir)
EMPTY_WORKTREE_DIR=$(make_empty_artifacts_dir)

EXIT_CODE=$(run_hook_with_dir "$MAIN_ARTIFACTS")
assert_eq "test_verifier_reads_correct_worktree: full dir exits 0" "0" "$EXIT_CODE"

EXIT_CODE=$(run_hook_with_dir "$EMPTY_WORKTREE_DIR")
assert_eq "test_verifier_reads_correct_worktree: empty dir exits 1" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_verifier_in_worktree_context
#
# Scenario: a simulated worktree with its own WORKFLOW_PLUGIN_ARTIFACTS_DIR
# containing all 5 required artifacts.  A second "main repo" dir also exists
# with all 5 artifacts (to rule out accidental cross-dir reads).
#
# - Verifier pointed at worktree's dir → exits 0.
# - An alternate dir (simulating the main repo's dir) exists but is NOT passed
#   via WORKFLOW_PLUGIN_ARTIFACTS_DIR.  We confirm the verifier did NOT silently
#   fall back to it by re-running with the empty version of the worktree dir.
# ---------------------------------------------------------------------------
WORKTREE_ARTIFACTS=$(make_full_artifacts_dir)
MAIN_REPO_ARTIFACTS=$(make_full_artifacts_dir)

# Verifier pointed at worktree's own artifacts dir with all steps present → exits 0
EXIT_CODE=$(run_hook_with_dir "$WORKTREE_ARTIFACTS")
assert_eq "test_verifier_in_worktree_context: worktree dir exits 0" "0" "$EXIT_CODE"

# Create a fresh empty dir to simulate same worktree dir but without artifacts.
# If the verifier were ignoring WORKFLOW_PLUGIN_ARTIFACTS_DIR and reading from the
# main repo dir (MAIN_REPO_ARTIFACTS), it would still exit 0.  It must exit 1.
EMPTY_WORKTREE_DIR2=$(make_empty_artifacts_dir)

EXIT_CODE=$(run_hook_with_dir "$EMPTY_WORKTREE_DIR2")
assert_eq "test_verifier_in_worktree_context: empty worktree dir exits 1 (does not use main repo dir)" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
print_summary
