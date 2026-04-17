#!/usr/bin/env bash
# tests/hooks/test-single-agent-integrate-structure.sh
# Structural boundary test (Behavioral Testing Standard Rule 5) for
# plugins/dso/skills/shared/prompts/single-agent-integrate.md.
#
# Rule 5: for non-executable LLM instruction files, test the structural
# boundary — required sections, sentinel strings, and interface anchors —
# NOT body text or prose phrasing.
#
# What we test (structural boundary):
#   - File exists at the expected path
#   - Step headings present (navigable structure)
#   - harvest-worktree shim reference (no .sh extension)
#   - REVIEW-WORKFLOW.md reference
#   - WORKTREE_PATH bash guard pattern
#   - cd $WORKTREE_PATH && CWD-prefix pattern
#   - CONTEXT ANCHOR sentinel (mandatory-continuation marker)
#   - ORCHESTRATOR_ROOT variable reference
#   - WORKTREE_ARTIFACTS computed inside WORKTREE_PATH context
#
# What we do NOT test (content assertions prohibited by Rule 5):
#   - Specific prose, rationale, or explanatory text
#   - Exact step wording or descriptions
#
# Usage:
#   bash tests/hooks/test-single-agent-integrate-structure.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_FILE="$REPO_ROOT/plugins/dso/skills/shared/prompts/single-agent-integrate.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-single-agent-integrate-structure.sh ==="

# ===========================================================================
# test_file_exists
# The target file must exist. All downstream assertions depend on it.
# Structural: file presence is the primary structural contract — an agent
# that references this path must find the file there.
# ===========================================================================
echo "--- test_file_exists ---"
# REVIEW-DEFENSE: This test is intentionally RED (TDD). The target file does not exist yet
# because it will be created in the subsequent implementation batch (bb34-0581). This is the
# correct TDD workflow — commit the RED test first, then create the implementation file that
# makes it GREEN. See epic c737-977d and CLAUDE.md rule 19 (TDD requirement).
if [[ -f "$TARGET_FILE" ]]; then
    assert_eq "test_file_exists: file present at expected path" "present" "present"
else
    assert_eq "test_file_exists: file present at expected path" "present" "missing"
fi

# ===========================================================================
# test_step_headings_present
# The file must contain step headings (## Step N or **Step N).
# Structural: step headings are the navigable interface — agents locate
# workflow stages via headings, not body prose.
# ===========================================================================
echo "--- test_step_headings_present ---"
if grep -qE "^## Step |^\*\*Step" "$TARGET_FILE" 2>/dev/null; then
    assert_eq "test_step_headings_present: step headings exist" "present" "present"
else
    assert_eq "test_step_headings_present: step headings exist" "present" "missing"
fi

# ===========================================================================
# test_harvest_worktree_shim_reference
# Must reference harvest-worktree without .sh extension (shim form).
# Structural: agents must invoke via the shim, not the raw script path.
# The .sh extension form would bypass the shim layer and break portability.
# ===========================================================================
echo "--- test_harvest_worktree_shim_reference ---"
if grep -qE "dso harvest-worktree|harvest-worktree[^.]" "$TARGET_FILE" 2>/dev/null; then
    # Also verify it does NOT use the .sh extension form
    if grep -q "harvest-worktree\.sh" "$TARGET_FILE" 2>/dev/null; then
        assert_eq "test_harvest_worktree_shim_reference: shim form (no .sh extension)" "no_extension" "has_extension"
    else
        assert_eq "test_harvest_worktree_shim_reference: shim form (no .sh extension)" "no_extension" "no_extension"
    fi
else
    assert_eq "test_harvest_worktree_shim_reference: harvest-worktree reference present" "present" "missing"
fi

# ===========================================================================
# test_review_workflow_reference
# Must contain a reference to REVIEW-WORKFLOW.md.
# Structural: the review workflow reference is an interface anchor that
# ensures agents consult the review protocol during integration.
# ===========================================================================
echo "--- test_review_workflow_reference ---"
if grep -q "REVIEW-WORKFLOW\.md" "$TARGET_FILE" 2>/dev/null; then
    assert_eq "test_review_workflow_reference: REVIEW-WORKFLOW.md referenced" "present" "present"
else
    assert_eq "test_review_workflow_reference: REVIEW-WORKFLOW.md referenced" "present" "missing"
fi

# ===========================================================================
# test_worktree_path_bash_guard
# Must contain the bash guard pattern: [ "$WORKTREE_PATH" =
# Structural: this guard is a mandatory safety check contract — its
# presence ensures the integration step validates WORKTREE_PATH before use.
# ===========================================================================
echo "--- test_worktree_path_bash_guard ---"
# shellcheck disable=SC2016  # single quotes intentional: grepping for literal string
# REVIEW-DEFENSE: -qF (fixed-string) required — the pattern contains `[` which grep
# interprets as a bracket expression in BRE/ERE mode, causing exit 2 instead of 1.
# Fixed-string mode matches the literal characters without regex interpretation.
if grep -qF '[ "$WORKTREE_PATH" =' "$TARGET_FILE" 2>/dev/null; then
    assert_eq "test_worktree_path_bash_guard: WORKTREE_PATH guard present" "present" "present"
else
    assert_eq "test_worktree_path_bash_guard: WORKTREE_PATH guard present" "present" "missing"
fi

# ===========================================================================
# test_cd_worktree_path_prefix
# Must contain the CWD-prefix pattern: cd $WORKTREE_PATH &&
# Structural: agents must scope bash calls to the worktree directory;
# this prefix pattern is the contract for that scoping behavior.
# ===========================================================================
echo "--- test_cd_worktree_path_prefix ---"
# shellcheck disable=SC2016  # single quotes intentional: grepping for literal string
if grep -q 'cd "$WORKTREE_PATH" &&' "$TARGET_FILE" 2>/dev/null; then
    assert_eq "test_cd_worktree_path_prefix: cd WORKTREE_PATH prefix present" "present" "present"
else
    assert_eq "test_cd_worktree_path_prefix: cd WORKTREE_PATH prefix present" "present" "missing"
fi

# ===========================================================================
# test_context_anchor_sentinel
# Must contain the exact string "CONTEXT ANCHOR".
# Structural: this sentinel marks the mandatory-continuation point —
# agents scan for this exact string to resume after context compaction.
# ===========================================================================
echo "--- test_context_anchor_sentinel ---"
if grep -q "CONTEXT ANCHOR" "$TARGET_FILE" 2>/dev/null; then
    assert_eq "test_context_anchor_sentinel: CONTEXT ANCHOR sentinel present" "present" "present"
else
    assert_eq "test_context_anchor_sentinel: CONTEXT ANCHOR sentinel present" "present" "missing"
fi

# ===========================================================================
# test_orchestrator_root_reference
# Must contain ORCHESTRATOR_ROOT variable reference.
# Structural: ORCHESTRATOR_ROOT is the interface variable that locates the
# session's root path — its presence confirms the integration prompt uses
# the correct path-scoping contract.
# ===========================================================================
echo "--- test_orchestrator_root_reference ---"
if grep -q "ORCHESTRATOR_ROOT" "$TARGET_FILE" 2>/dev/null; then
    assert_eq "test_orchestrator_root_reference: ORCHESTRATOR_ROOT present" "present" "present"
else
    assert_eq "test_orchestrator_root_reference: ORCHESTRATOR_ROOT present" "present" "missing"
fi

# ===========================================================================
# test_worktree_artifacts_in_worktree_context
# Must contain WORKTREE_ARTIFACTS AND show it computed inside WORKTREE_PATH
# context (cd into WORKTREE_PATH before getting artifacts dir).
# Structural: WORKTREE_ARTIFACTS must be scoped to the worktree — computing
# it outside would yield the orchestrator's path, breaking harvest attestation.
# ===========================================================================
echo "--- test_worktree_artifacts_in_worktree_context ---"
_has_worktree_artifacts=0
_has_context_pattern=0

if grep -q "WORKTREE_ARTIFACTS" "$TARGET_FILE" 2>/dev/null; then
    _has_worktree_artifacts=1
fi

_context_count=$(grep -Ec 'cd.*WORKTREE_PATH.*get_artifacts_dir|WORKTREE_PATH.*source.*get_artifacts_dir' "$TARGET_FILE" 2>/dev/null || echo 0)
if [[ "$_context_count" -gt 0 ]]; then
    _has_context_pattern=1
fi

if [[ "$_has_worktree_artifacts" -eq 1 && "$_has_context_pattern" -eq 1 ]]; then
    assert_eq "test_worktree_artifacts_in_worktree_context: WORKTREE_ARTIFACTS computed in WORKTREE_PATH context" "present" "present"
elif [[ "$_has_worktree_artifacts" -eq 0 ]]; then
    assert_eq "test_worktree_artifacts_in_worktree_context: WORKTREE_ARTIFACTS variable present" "present" "missing"
else
    assert_eq "test_worktree_artifacts_in_worktree_context: WORKTREE_ARTIFACTS computed in WORKTREE_PATH context" "present" "context_pattern_missing"
fi

print_summary
