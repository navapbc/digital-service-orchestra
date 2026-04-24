#!/usr/bin/env bash
# tests/hooks/test-residual-state-e2e.sh
# End-to-end structural boundary test for the residual-state blind spot epic (a171-6c65).
#
# Confirms all mechanisms added by the epic are present across all modified files,
# and includes regression assertions verifying that original content is preserved
# (original Part B probes such as sync loops and race conditions, original 6
# red-team categories, original Part C trigger condition).
#
# Per behavioral-testing-standard.md Rule 5 — for non-executable instruction files,
# test the structural boundary (section headings, enum values, tool names), NOT prose.
#
# Tests:
#   test_part_b_residual_state_probe_present
#   test_part_c_trigger_expanded
#   test_red_team_residual_references_category
#   test_blue_team_escalate_to_epic_recognized
#   test_orchestrator_escalate_to_epic_handler
#   test_brainstorm_sc_revision_logic
#   test_regression_original_part_b_probes_preserved
#   test_regression_original_red_team_categories_preserved
#
# Usage: bash tests/hooks/test-residual-state-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
LIB_DIR="$SCRIPT_DIR/../lib"

source "$LIB_DIR/assert.sh"

PIPELINE_MD="${REPO_ROOT}/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"
RED_TEAM_MD="${REPO_ROOT}/plugins/dso/agents/red-team-reviewer.md"
BLUE_TEAM_MD="${REPO_ROOT}/plugins/dso/agents/blue-team-filter.md"
PREPLANNING_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"
BRAINSTORM_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

# skill-refactor: brainstorm phases extracted. Rebind BRAINSTORM_MD to aggregated corpus
# (SKILL.md + phases/*.md + verifiable-sc-check.md).
_orig_BRAINSTORM_MD="$BRAINSTORM_MD"
source "$(git rev-parse --show-toplevel)/tests/skills/lib/brainstorm-skill-aggregate.sh"
BRAINSTORM_MD=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT


# ---------------------------------------------------------------------------
# test_part_b_residual_state_probe_present
#
# Given: epic-scrutiny-pipeline.md Part B section exists
# When:  grep for the residual-state probe canonical phrase
#        "deprecate, relocate, or rename any file paths"
# Then:  phrase is present (probe was added by this epic)
# ---------------------------------------------------------------------------
test_part_b_residual_state_probe_present() {
  echo "--- test_part_b_residual_state_probe_present ---"

  local present="false"
  if grep -q "deprecate, relocate, or rename any file paths" "$PIPELINE_MD" 2>/dev/null; then
    present="true"
  fi

  assert_eq \
    "Part B contains residual-state probe (deprecate/relocate/rename paths)" \
    "true" "$present"
}

# ---------------------------------------------------------------------------
# test_part_c_trigger_expanded
#
# Given: epic-scrutiny-pipeline.md Part C trigger line exists
# When:  grep for "moving, deprecating, removing, or renaming" in the file
# Then:  all four trigger conditions are present in the expanded Part C trigger
# ---------------------------------------------------------------------------
test_part_c_trigger_expanded() {
  echo "--- test_part_c_trigger_expanded ---"

  local present="false"
  if grep -q "moving, deprecating, removing, or renaming" "$PIPELINE_MD" 2>/dev/null; then
    present="true"
  fi

  assert_eq \
    "Part C trigger includes moving/deprecating/removing/renaming" \
    "true" "$present"
}

# ---------------------------------------------------------------------------
# test_red_team_residual_references_category
#
# Given: red-team-reviewer.md Interaction Gap Taxonomy section
# When:  grep for "Residual References" category heading and
#        "residual_references" taxonomy_category enum value and
#        "escalate_to_epic" type enum value
# Then:  all three structural contract elements are present
# ---------------------------------------------------------------------------
test_red_team_residual_references_category() {
  echo "--- test_red_team_residual_references_category ---"

  local category_present="false"
  if grep -q "Residual References" "$RED_TEAM_MD" 2>/dev/null; then
    category_present="true"
  fi
  assert_eq \
    "red-team-reviewer.md has Residual References category" \
    "true" "$category_present"

  local enum_present="false"
  if grep -q "residual_references" "$RED_TEAM_MD" 2>/dev/null; then
    enum_present="true"
  fi
  assert_eq \
    "red-team-reviewer.md taxonomy_category enum includes residual_references" \
    "true" "$enum_present"

  local type_present="false"
  if grep -q "escalate_to_epic" "$RED_TEAM_MD" 2>/dev/null; then
    type_present="true"
  fi
  assert_eq \
    "red-team-reviewer.md type enum includes escalate_to_epic" \
    "true" "$type_present"
}

# ---------------------------------------------------------------------------
# test_blue_team_escalate_to_epic_recognized
#
# Given: blue-team-filter.md Field Definitions section
# When:  grep for "escalate_to_epic" in the schema
# Then:  blue team passes through escalate_to_epic finding type
# ---------------------------------------------------------------------------
test_blue_team_escalate_to_epic_recognized() {
  echo "--- test_blue_team_escalate_to_epic_recognized ---"

  local present="false"
  if grep -q "escalate_to_epic" "$BLUE_TEAM_MD" 2>/dev/null; then
    present="true"
  fi

  assert_eq \
    "blue-team-filter.md recognizes escalate_to_epic in output schema" \
    "true" "$present"
}

# ---------------------------------------------------------------------------
# test_orchestrator_escalate_to_epic_handler
#
# Given: preplanning SKILL.md Phase 2.5 finding type dispatch table
# When:  grep for "escalate_to_epic" handler entry
# Then:  preplanning orchestrator has a dispatch route for escalate_to_epic
# ---------------------------------------------------------------------------
test_orchestrator_escalate_to_epic_handler() {
  echo "--- test_orchestrator_escalate_to_epic_handler ---"

  local present="false"
  if grep -q "escalate_to_epic" "$PREPLANNING_MD" 2>/dev/null; then
    present="true"
  fi

  assert_eq \
    "preplanning SKILL.md has escalate_to_epic handler in Phase 2.5 dispatch" \
    "true" "$present"
}

# ---------------------------------------------------------------------------
# test_brainstorm_sc_revision_logic
#
# Given: brainstorm SKILL.md, between FEASIBILITY_GAP handler and Step 4
# When:  grep for "SC Gap Check" section heading and "AskUserQuestion" tool name
# Then:  SC revision logic is present with re-approval gate
# ---------------------------------------------------------------------------
test_brainstorm_sc_revision_logic() {
  echo "--- test_brainstorm_sc_revision_logic ---"

  local section_present="false"
  if grep -qE "^#{1,6}\s.*SC\s+Gap" "$BRAINSTORM_MD" 2>/dev/null; then
    section_present="true"
  fi
  assert_eq \
    "brainstorm SKILL.md has SC Gap Check section heading" \
    "true" "$section_present"

  local reapproval_present="false"
  if grep -q "AskUserQuestion" "$BRAINSTORM_MD" 2>/dev/null; then
    reapproval_present="true"
  fi
  assert_eq \
    "brainstorm SKILL.md uses AskUserQuestion for SC re-approval" \
    "true" "$reapproval_present"
}

# ---------------------------------------------------------------------------
# test_regression_original_part_b_probes_preserved
#
# Given: epic-scrutiny-pipeline.md Part B section
# When:  grep for original probes: "sync loops" and "race conditions"
# Then:  original Part B probes are still present (not overwritten by new probe)
# ---------------------------------------------------------------------------
test_regression_original_part_b_probes_preserved() {
  echo "--- test_regression_original_part_b_probes_preserved ---"

  local sync_loops_present="false"
  if grep -q "sync loops" "$PIPELINE_MD" 2>/dev/null; then
    sync_loops_present="true"
  fi
  assert_eq \
    "REGRESSION: Part B still contains original 'sync loops' probe" \
    "true" "$sync_loops_present"

  local race_conditions_present="false"
  if grep -q "race conditions" "$PIPELINE_MD" 2>/dev/null; then
    race_conditions_present="true"
  fi
  assert_eq \
    "REGRESSION: Part B still contains original 'race conditions' probe" \
    "true" "$race_conditions_present"
}

# ---------------------------------------------------------------------------
# test_regression_original_red_team_categories_preserved
#
# Given: red-team-reviewer.md Interaction Gap Taxonomy
# When:  grep for original category taxonomy_category values
# Then:  original 6 categories are still present alongside new residual_references
# ---------------------------------------------------------------------------
test_regression_original_red_team_categories_preserved() {
  echo "--- test_regression_original_red_team_categories_preserved ---"

  local all_present="true"
  for category in implicit_shared_state conflicting_assumptions dependency_gap scope_overlap ordering_violation consumer_impact; do
    if ! grep -q "$category" "$RED_TEAM_MD" 2>/dev/null; then
      all_present="false"
      echo "  MISSING original category: $category"
    fi
  done

  assert_eq \
    "REGRESSION: red-team-reviewer.md original 6 taxonomy categories preserved" \
    "true" "$all_present"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-residual-state-e2e.sh ==="

test_part_b_residual_state_probe_present
test_part_c_trigger_expanded
test_red_team_residual_references_category
test_blue_team_escalate_to_epic_recognized
test_orchestrator_escalate_to_epic_handler
test_brainstorm_sc_revision_logic
test_regression_original_part_b_probes_preserved
test_regression_original_red_team_categories_preserved

print_summary
