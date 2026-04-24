#!/usr/bin/env bash
# tests/scripts/test-implementation-plan-contracts.sh
# RED tests: verify implementation-plan SKILL.md has cross-component contract detection pass.
#
# TDD RED phase: all 5 tests FAIL until the GREEN story (w21-kp0l) adds the
# ### Contract Detection Pass section to implementation-plan SKILL.md.
#
# Tests:
#  1. test_contract_detection_section_exists   — grep for '### Contract Detection Pass' heading
#  2. test_contract_emit_parse_pattern         — grep for emit.*signal and parse.*signal within
#                                                the Contract Detection Pass section only
#  3. test_contract_orchestrator_subagent_pattern — grep for orchestrator/sub-agent report schema
#  4. test_contract_deduplication             — grep for 'ticket deps' AND deduplication guard
#  5. test_contract_task_template             — grep for contract task template with artifact path
#
# Usage: bash tests/scripts/test-implementation-plan-contracts.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
IMPL_PLAN_SKILL="$DSO_PLUGIN_DIR/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-contracts.sh ==="
echo ""

# ── test_contract_detection_section_exists ────────────────────────────────────
# Verify implementation-plan SKILL.md contains '### Contract Detection Pass' heading.
# RED: FAIL because SKILL.md does not yet have this section.
test_contract_detection_section_exists() {
  _snapshot_fail
  local _found=0
  grep -q "### Contract Detection Pass" "$IMPL_PLAN_SKILL" && _found=1
  assert_eq "test_contract_detection_section_exists: '### Contract Detection Pass' heading present" \
    "1" "$_found"
  assert_pass_if_clean "test_contract_detection_section_exists"
}

# ── test_contract_emit_parse_pattern ─────────────────────────────────────────
# Verify SKILL.md contract detection section contains emit/parse signal pair detection.
# Uses awk to scope the search to the Contract Detection Pass section only —
# preventing false positives from pre-existing 'parse' occurrences elsewhere in SKILL.md
# (e.g. 'parse findings' on line 76, 'git rev-parse' on line 528).
# RED: FAIL because the contract detection section does not yet exist.
test_contract_emit_parse_pattern() {
  _snapshot_fail
  # Extract only the Contract Detection Pass section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Contract Detection Pass/{found=1} found && /^### / && !/^### Contract Detection Pass/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_emit=0 _has_parse_signal=0
  _tmp="$_section"; [[ "$_tmp" =~ emit ]] && _has_emit=1
  _tmp="$_section"; [[ "$_tmp" =~ parse.*signal|signal.*parse ]] && _has_parse_signal=1
  assert_eq "test_contract_emit_parse_pattern: 'emit' within Contract Detection Pass section" \
    "1" "$_has_emit"
  assert_eq "test_contract_emit_parse_pattern: 'parse.*signal' within Contract Detection Pass section" \
    "1" "$_has_parse_signal"
  assert_pass_if_clean "test_contract_emit_parse_pattern"
}

# ── test_contract_orchestrator_subagent_pattern ───────────────────────────────
# Verify SKILL.md contains orchestrator/sub-agent report schema pattern in the
# contract detection context.
# RED: FAIL because the contract detection section does not yet exist.
test_contract_orchestrator_subagent_pattern() {
  _snapshot_fail
  local _found=0
  grep -qE "CONTRACT_REPORT|contract.*report|report.*schema|orchestrator.*contract|contract.*orchestrat" \
    "$IMPL_PLAN_SKILL" && _found=1
  assert_eq "test_contract_orchestrator_subagent_pattern: orchestrator/sub-agent report schema present" \
    "1" "$_found"
  assert_pass_if_clean "test_contract_orchestrator_subagent_pattern"
}

# ── test_contract_deduplication ───────────────────────────────────────────────
# Verify SKILL.md contract detection section contains a 'ticket deps' dedup
# guard AND references to 'existing contract' or 'Contract:' to avoid creating
# duplicate contract tasks.
# Uses awk to scope the search to the Contract Detection Pass section only.
test_contract_deduplication() {
  _snapshot_fail
  # Extract only the Contract Detection Pass section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Contract Detection Pass/{found=1} found && /^### / && !/^### Contract Detection Pass/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_deps_cmd=0 _has_contract_ref=0
  _tmp="$_section"; [[ "$_tmp" == *"ticket deps"* ]] && _has_deps_cmd=1
  _tmp="$_section"; { [[ "$_tmp" == *"existing contract"* ]] || [[ "$_tmp" == *"Contract:"* ]]; } \
    && _has_contract_ref=1
  assert_eq "test_contract_deduplication: 'ticket deps' within Contract Detection Pass section" \
    "1" "$_has_deps_cmd"
  assert_eq "test_contract_deduplication: 'existing contract' or 'Contract:' within Contract Detection Pass section" \
    "1" "$_has_contract_ref"
  assert_pass_if_clean "test_contract_deduplication"
}

# ── test_contract_task_template ───────────────────────────────────────────────
# Verify SKILL.md contains contract task template referencing the
# 'docs/contracts/' artifact path (canonical form uses ${CLAUDE_PLUGIN_ROOT}/docs/contracts/).
test_contract_task_template() {
  _snapshot_fail
  local _found=0
  grep -q "docs/contracts/" "$IMPL_PLAN_SKILL" && _found=1
  assert_eq "test_contract_task_template: 'docs/contracts/' artifact path present" \
    "1" "$_found"
  assert_pass_if_clean "test_contract_task_template"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_contract_detection_section_exists
test_contract_emit_parse_pattern
test_contract_orchestrator_subagent_pattern
test_contract_deduplication
test_contract_task_template

print_summary
