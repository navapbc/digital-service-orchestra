#!/usr/bin/env bash
# tests/skills/test-task-decomposer-verify-robustness.sh
# Structural contract test: Verify-command robustness guidance (bug d792-2c16-71a5-4687).
#
# Asserts that the four files modified by FIX-B-FULL contain the new
# structural sections and dimensions introduced to prevent recurring
# AC defect categories in task-decomposer output.
#
# Per behavioral-testing-standard.md Rule 5: instruction-file tests assert
# only on binding tokens that are parsed or referenced by downstream consumers.
#
# Usage:
#   bash tests/skills/test-task-decomposer-verify-robustness.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TASK_DECOMPOSER="$REPO_ROOT/plugins/dso/agents/task-decomposer.md"
TASK_DESIGN_REVIEWER="$REPO_ROOT/plugins/dso/skills/implementation-plan/docs/reviewers/plan/task-design.md"
COMPLETENESS_REVIEWER="$REPO_ROOT/plugins/dso/skills/implementation-plan/docs/reviewers/plan/completeness.md"
GAP_ANALYSIS="$REPO_ROOT/plugins/dso/skills/implementation-plan/prompts/gap-analysis.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-task-decomposer-verify-robustness.sh ==="
echo ""

# ---------------------------------------------------------------------------
# task-decomposer.md: Verify-Command Robustness sub-section present in Step 5
# ---------------------------------------------------------------------------
test_task_decomposer_robustness_section_present() {
  local found=0
  grep -q "Verify-Command Robustness" "$TASK_DECOMPOSER" 2>/dev/null && found=1
  assert_eq \
    "task-decomposer Step 5: Verify-Command Robustness sub-section must be present" \
    "1" "$found"
}

test_task_decomposer_robustness_checklist_items() {
  # Spot-check several binding pattern keywords from the 11-item checklist.
  # Each is a distinct defect category that downstream consumers (plan-reviewer,
  # gap-analysis) are expected to cross-reference.
  local items_present=1
  local keywords=(
    "Word-boundary matching"
    "Shell expansion in Verify strings"
    "Helper script invocation signature"
    "Fixture independence"
    "Cardinality guards"
    "Format tolerance"
    "Structured-artifact assertion target"
    "Prerequisite-state ACs"
    "Conflicting ACs need a resolution AC"
    "Positive next-section anchors"
    "Sibling-task file references"
  )
  for kw in "${keywords[@]}"; do
    if ! grep -qF "$kw" "$TASK_DECOMPOSER" 2>/dev/null; then
      echo "  MISSING keyword in task-decomposer.md: $kw"
      items_present=0
    fi
  done
  assert_eq \
    "task-decomposer Step 5: all 11 robustness checklist items must be present" \
    "1" "$items_present"
}

test_task_decomposer_step8_robustness_selfverify() {
  local found=0
  grep -q "Verify-Command Robustness" "$TASK_DECOMPOSER" 2>/dev/null && \
    grep -q "Step 8" "$TASK_DECOMPOSER" 2>/dev/null && found=1
  # Step 8 item references the checklist by section name
  local step8_refs_checklist=0
  grep -A5 "^8\." "$TASK_DECOMPOSER" 2>/dev/null | grep -q "Verify-Command Robustness" && step8_refs_checklist=1
  assert_eq \
    "task-decomposer Step 8: self-verify item must reference the Verify-Command Robustness checklist" \
    "1" "$step8_refs_checklist"
}

# ---------------------------------------------------------------------------
# task-design.md: verify_command_robustness dimension present
# ---------------------------------------------------------------------------
test_task_design_has_verify_robustness_dimension() {
  local found=0
  grep -q "verify_command_robustness" "$TASK_DESIGN_REVIEWER" 2>/dev/null && found=1
  assert_eq \
    "task-design.md: verify_command_robustness dimension must be present" \
    "1" "$found"
}

test_task_design_dimension_not_nullable() {
  # The dimension is never null per the rubric — confirm the JSON schema block
  # documents it as an integer (not 'null'), matching the completeness reviewer
  # pattern for dd_collective_ac_coverage.
  local found_integer=0
  grep -A2 '"verify_command_robustness"' "$TASK_DESIGN_REVIEWER" 2>/dev/null | \
    grep -q 'integer 1-5' && found_integer=1
  assert_eq \
    "task-design.md: verify_command_robustness schema entry must declare integer 1-5 (non-nullable)" \
    "1" "$found_integer"
}

# ---------------------------------------------------------------------------
# completeness.md: ac_semantic_consistency extended to cover execution correctness
# ---------------------------------------------------------------------------
test_completeness_ac_semantic_covers_execution() {
  # The extended definition should mention execution-correctness indicators
  # present in the updated text: "executable as written" is the binding phrase.
  local found=0
  grep -q "executable as written" "$COMPLETENESS_REVIEWER" 2>/dev/null && found=1
  assert_eq \
    "completeness.md: ac_semantic_consistency must extend to execution correctness ('executable as written')" \
    "1" "$found"
}

test_completeness_ac_semantic_covers_shell_expansion() {
  local found=0
  grep -q "shell" "$COMPLETENESS_REVIEWER" 2>/dev/null && found=1
  assert_eq \
    "completeness.md: ac_semantic_consistency must mention shell-expansion as a defect signal" \
    "1" "$found"
}

# ---------------------------------------------------------------------------
# gap-analysis.md: ac_verify_defect taxonomy category present
# ---------------------------------------------------------------------------
test_gap_analysis_has_ac_verify_defect_category() {
  local found=0
  grep -q "ac_verify_defect" "$GAP_ANALYSIS" 2>/dev/null && found=1
  assert_eq \
    "gap-analysis.md: ac_verify_defect taxonomy category must be present" \
    "1" "$found"
}

test_gap_analysis_taxonomy_category_field_includes_new_value() {
  # The taxonomy_category field definition must list ac_verify_defect
  local found=0
  grep "taxonomy_category" "$GAP_ANALYSIS" 2>/dev/null | grep -q "ac_verify_defect" && found=1
  assert_eq \
    "gap-analysis.md: taxonomy_category field definition must include ac_verify_defect" \
    "1" "$found"
}

test_gap_analysis_ac_verify_defect_section_present() {
  # Structural: the named section heading must exist so the taxonomy is navigable
  local found=0
  grep -q "### 6. AC Verify-Command Defects" "$GAP_ANALYSIS" 2>/dev/null && found=1
  assert_eq \
    "gap-analysis.md: '### 6. AC Verify-Command Defects' section must be present" \
    "1" "$found"
}

# Run all tests
test_task_decomposer_robustness_section_present
test_task_decomposer_robustness_checklist_items
test_task_decomposer_step8_robustness_selfverify
test_task_design_has_verify_robustness_dimension
test_task_design_dimension_not_nullable
test_completeness_ac_semantic_covers_execution
test_completeness_ac_semantic_covers_shell_expansion
test_gap_analysis_has_ac_verify_defect_category
test_gap_analysis_taxonomy_category_field_includes_new_value
test_gap_analysis_ac_verify_defect_section_present

print_summary
