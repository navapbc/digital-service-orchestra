#!/usr/bin/env bash
# tests/scripts/test-implementation-plan-proposals.sh
# RED tests: verify implementation-plan SKILL.md has proposal generation section structure.
#
# TDD RED phase: all 4 tests FAIL until the GREEN story adds the
# ### Proposal Generation section to implementation-plan SKILL.md.
#
# Tests:
#  1. test_proposal_generation_section_exists   — grep for '### Proposal Generation' heading
#  2. test_minimum_proposals_requirement        — awk-scoped to Proposal Generation section,
#                                                 grep for "at least 3" or "minimum.*3"
#  3. test_proposal_format_fields               — awk-scoped, grep for all 6 fields:
#                                                 title, description, files, pros, cons, risk
#  4. test_distinctness_validation_gate         — awk-scoped, grep for distinctness with
#                                                 structural axes: data layer, control flow,
#                                                 dependency, interface boundary
#
# Usage: bash tests/scripts/test-implementation-plan-proposals.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
IMPL_PLAN_SKILL="$DSO_PLUGIN_DIR/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-proposals.sh ==="
echo ""

# ── test_proposal_generation_section_exists ───────────────────────────────────
# Verify implementation-plan SKILL.md contains '### Proposal Generation' heading.
# RED: FAIL because SKILL.md does not yet have this section.
test_proposal_generation_section_exists() {
  _snapshot_fail
  local _found=0
  grep -q "### Proposal Generation" "$IMPL_PLAN_SKILL" && _found=1
  assert_eq "test_proposal_generation_section_exists: '### Proposal Generation' heading present" \
    "1" "$_found"
  assert_pass_if_clean "test_proposal_generation_section_exists"
}

# ── test_minimum_proposals_requirement ────────────────────────────────────────
# Verify SKILL.md Proposal Generation section requires at least 3 proposals.
# Uses awk to scope the search to the Proposal Generation section only —
# preventing false positives from pre-existing content elsewhere in SKILL.md.
# RED: FAIL because the proposal generation section does not yet exist.
test_minimum_proposals_requirement() {
  _snapshot_fail
  # Extract only the Proposal Generation section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Proposal Generation/{found=1} found && /^### / && !/^### Proposal Generation/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_minimum=0
  { echo "$_section" | grep -qiE "at least 3|minimum.*3|3.*minimum"; } && _has_minimum=1
  assert_eq "test_minimum_proposals_requirement: 'at least 3' or 'minimum.*3' within Proposal Generation section" \
    "1" "$_has_minimum"
  assert_pass_if_clean "test_minimum_proposals_requirement"
}

# ── test_proposal_format_fields ───────────────────────────────────────────────
# Verify SKILL.md Proposal Generation section contains all 6 required fields:
# title, description, files, pros, cons, risk.
# Uses awk to scope the search to the Proposal Generation section only —
# preventing false positives from pre-existing field names elsewhere in SKILL.md.
# RED: FAIL because the proposal generation section does not yet exist.
test_proposal_format_fields() {
  _snapshot_fail
  # Extract only the Proposal Generation section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Proposal Generation/{found=1} found && /^### / && !/^### Proposal Generation/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_title=0 _has_description=0 _has_files=0 _has_pros=0 _has_cons=0 _has_risk=0
  echo "$_section" | grep -qi "title" && _has_title=1
  echo "$_section" | grep -qi "description" && _has_description=1
  echo "$_section" | grep -qi "files" && _has_files=1
  echo "$_section" | grep -qi "pros" && _has_pros=1
  echo "$_section" | grep -qi "cons" && _has_cons=1
  echo "$_section" | grep -qi "risk" && _has_risk=1
  assert_eq "test_proposal_format_fields: 'title' field within Proposal Generation section" \
    "1" "$_has_title"
  assert_eq "test_proposal_format_fields: 'description' field within Proposal Generation section" \
    "1" "$_has_description"
  assert_eq "test_proposal_format_fields: 'files' field within Proposal Generation section" \
    "1" "$_has_files"
  assert_eq "test_proposal_format_fields: 'pros' field within Proposal Generation section" \
    "1" "$_has_pros"
  assert_eq "test_proposal_format_fields: 'cons' field within Proposal Generation section" \
    "1" "$_has_cons"
  assert_eq "test_proposal_format_fields: 'risk' field within Proposal Generation section" \
    "1" "$_has_risk"
  assert_pass_if_clean "test_proposal_format_fields"
}

# ── test_distinctness_validation_gate ─────────────────────────────────────────
# Verify SKILL.md Proposal Generation section contains distinctness validation
# with structural axes: data layer, control flow, dependency, interface boundary.
# Uses awk to scope the search to the Proposal Generation section only —
# preventing false positives from pre-existing 'interface' or 'dependency'
# occurrences elsewhere in SKILL.md.
# RED: FAIL because the proposal generation section does not yet exist.
test_distinctness_validation_gate() {
  _snapshot_fail
  # Extract only the Proposal Generation section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Proposal Generation/{found=1} found && /^### / && !/^### Proposal Generation/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_distinctness=0 _has_data_layer=0 _has_control_flow=0 _has_dependency=0 _has_interface=0
  echo "$_section" | grep -qi "distinct" && _has_distinctness=1
  echo "$_section" | grep -qi "data layer" && _has_data_layer=1
  echo "$_section" | grep -qi "control flow" && _has_control_flow=1
  echo "$_section" | grep -qi "dependency" && _has_dependency=1
  echo "$_section" | grep -qi "interface boundary\|interface_boundary" && _has_interface=1
  assert_eq "test_distinctness_validation_gate: 'distinct' within Proposal Generation section" \
    "1" "$_has_distinctness"
  assert_eq "test_distinctness_validation_gate: 'data layer' axis within Proposal Generation section" \
    "1" "$_has_data_layer"
  assert_eq "test_distinctness_validation_gate: 'control flow' axis within Proposal Generation section" \
    "1" "$_has_control_flow"
  assert_eq "test_distinctness_validation_gate: 'dependency' axis within Proposal Generation section" \
    "1" "$_has_dependency"
  assert_eq "test_distinctness_validation_gate: 'interface boundary' axis within Proposal Generation section" \
    "1" "$_has_interface"
  assert_pass_if_clean "test_distinctness_validation_gate"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_proposal_generation_section_exists
test_minimum_proposals_requirement
test_proposal_format_fields
test_distinctness_validation_gate

print_summary
