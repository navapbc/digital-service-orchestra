#!/usr/bin/env bash
# tests/workflows/test-ci-integration-review-scope.sh
# RED-phase behavioral tests for .github/workflows/ci.yml
#
# Story 5bd2-d046-d951-47d7: CI llm-review job uses narrow integration scope
# for session→main PRs: verify-session-provenance.sh identifies unprovenanced
# commits, cross-branch file set is computed from DSO-Story-Merge trailers,
# both are unioned into the review diff, an empty-scope guard exits 0 early,
# and prior-cycle TrackerDefenseStore defenses are suppressed.
#
# All 6 tests FAIL RED because ci.yml does not have this logic yet.
#
# Usage: bash tests/workflows/test-ci-integration-review-scope.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/ci.yml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ci-integration-review-scope.sh ==="

# ── test_calls_verify_session_provenance ─────────────────────────────────────
# The llm-review job must call verify-session-provenance.sh to identify commits
# in the session→main PR that are not provenanced by a DSO-Story-Merge trailer
# or a linked PR. The resulting unprovenanced-shas.txt drives scope.
_snapshot_fail
found=0
grep -q "verify-session-provenance.sh" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
assert_eq "test_calls_verify_session_provenance: llm-review job calls verify-session-provenance.sh" "1" "$found"
assert_pass_if_clean "test_calls_verify_session_provenance"

# ── test_computes_cross_branch_file_set ──────────────────────────────────────
# The llm-review job must parse DSO-Story-Merge trailers in the session PR to
# discover which files were touched by ≥2 sub-branches (cross-branch file set).
# Look for DSO-Story-Merge trailer parsing combined with file-grouping logic
# (e.g. collecting files per story, then intersecting / counting ≥2 occurrences).
_snapshot_fail
found=0
grep -q "DSO-Story-Merge" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
assert_eq "test_computes_cross_branch_file_set: llm-review job parses DSO-Story-Merge trailers to compute cross-branch file set" "1" "$found"
assert_pass_if_clean "test_computes_cross_branch_file_set"

# ── test_unions_scope_for_review ─────────────────────────────────────────────
# The llm-review job must union the unprovenanced-shas.txt scope with the
# cross-branch file set before feeding the diff into ci-llm-review-runner.sh.
# Look for explicit references to unprovenanced-shas.txt being combined with
# cross-branch files for the integration review diff.
_snapshot_fail
found=0
grep -q "unprovenanced-shas.txt" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
assert_eq "test_unions_scope_for_review: llm-review job references unprovenanced-shas.txt for integration review scope union" "1" "$found"
assert_pass_if_clean "test_unions_scope_for_review"

# ── test_handles_dso_review_cycle ────────────────────────────────────────────
# The llm-review job must compute or set DSO_REVIEW_CYCLE specifically for the
# session→main integration review (distinct from per-branch review cycles).
# The integration review must use its own cycle counter, not reuse the
# per-branch counter, so look for an integration-review-specific cycle step.
_snapshot_fail
found=0
grep -q "integration.*review.*cycle\|DSO_INTEGRATION_REVIEW_CYCLE\|integration-review.*DSO_REVIEW_CYCLE" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
assert_eq "test_handles_dso_review_cycle: llm-review job computes DSO_REVIEW_CYCLE for integration (session→main) review" "1" "$found"
assert_pass_if_clean "test_handles_dso_review_cycle"

# ── test_empty_scope_exits_zero ──────────────────────────────────────────────
# If the union of unprovenanced scope + cross-branch files is empty, the
# llm-review job must exit 0 without invoking ci-llm-review-runner.sh.
# This prevents spurious LLM calls on fully-provenanced, single-story PRs.
# Look for an empty-scope guard (e.g. "no files to review", "INTEGRATION_SCOPE
# is empty", or an explicit early-exit comment).
_snapshot_fail
found=0
grep -qE "integration.scope.*empty|no.*files.*review|INTEGRATION_SCOPE.*empty|empty.*integration.*scope|skip.*integration.*review" \
    "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
assert_eq "test_empty_scope_exits_zero: llm-review job has empty-scope guard that exits 0 when no unprovenanced or cross-branch files" "1" "$found"
assert_pass_if_clean "test_empty_scope_exits_zero"

# ── test_suppresses_prior_defenses ───────────────────────────────────────────
# The integration review must suppress TrackerDefenseStore defenses from prior
# review cycles so the reviewer does not double-count already-defended findings.
# Look for a suppress-prior-defenses flag, a DSO_SUPPRESS_PRIOR_DEFENSES env
# var, or an explicit "suppress" step in the integration review section of ci.yml.
_snapshot_fail
found=0
grep -qE "suppress.prior.defenses|DSO_SUPPRESS_PRIOR_DEFENSES|suppress-prior-defenses" \
    "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
assert_eq "test_suppresses_prior_defenses: llm-review job suppresses prior-cycle TrackerDefenseStore defenses in integration review" "1" "$found"
assert_pass_if_clean "test_suppresses_prior_defenses"

print_summary
