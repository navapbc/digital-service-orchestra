#!/usr/bin/env bash
# tests/workflows/test-review-workflow-compute-hash-path.sh
# RED test for bug 54af-5307: REVIEW-WORKFLOW.md uses ${CLAUDE_PLUGIN_ROOT}/hooks/compute-diff-hash.sh
# which can point to a stale plugin cache rather than the worktree's copy, causing hash mismatches.
#
# Fix: REVIEW-WORKFLOW.md must instruct agents to use $REPO_ROOT/plugins/dso/hooks/compute-diff-hash.sh
# (canonical worktree path) — never ${CLAUDE_PLUGIN_ROOT}/hooks/compute-diff-hash.sh for hash capture.
#
# Test:
#   test_review_workflow_uses_repo_root_for_compute_hash — REVIEW-WORKFLOW.md must NOT contain
#     ${CLAUDE_PLUGIN_ROOT}/hooks/compute-diff-hash.sh for the DIFF_HASH capture step.
#
# Usage: bash tests/workflows/test-review-workflow-compute-hash-path.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_WORKFLOW="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-workflow-compute-hash-path.sh ==="

# ── test_review_workflow_uses_repo_root_for_compute_hash ──────────────────────
# REVIEW-WORKFLOW.md must NOT instruct agents to use ${CLAUDE_PLUGIN_ROOT}/hooks/compute-diff-hash.sh
# for DIFF_HASH or NEW_DIFF_HASH capture. Using the plugin cache path causes hash mismatches in
# worktree sessions where the cache version differs from the worktree version.
_snapshot_fail
plugin_root_hash_refs=0
grep -q 'CLAUDE_PLUGIN_ROOT.*compute-diff-hash' "$REVIEW_WORKFLOW" 2>/dev/null && plugin_root_hash_refs=1 || true
assert_eq "test_review_workflow_uses_repo_root_for_compute_hash" "0" "$plugin_root_hash_refs"
assert_pass_if_clean "test_review_workflow_uses_repo_root_for_compute_hash"

print_summary
