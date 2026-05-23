#!/usr/bin/env bash
# tests/scripts/test-loop-touchpoint-implplan-steps.sh
# Behavioral fixture: verify implementation-plan/SKILL.md Steps 2, 4, and 6
# each contain the shared remediation loop protocol block (all 6 DD scenarios
# × 3 touchpoints = 18 tests total).
#
# Tests (6 DD scenarios × 3 touchpoints):
#  1. test_cycle_declaration_step{2,4,6}       — 'Current cycle: N of MAX_CYCLES'
#  2. test_oscillation_check_gate_step{2,4,6}  — oscillation-check + cycle >= 2 gate
#  3. test_halt_vs_replan_exclusivity_step{2,4,6} — HALT-vs-REPLAN exclusivity language
#  4. test_terminal_replan_escalate_step{2,4,6} — REPLAN_ESCALATE: planner_supplied
#  5. test_mid_loop_success_exit_step{2,4,6}   — success-exit language
#  6. test_protocol_error_step{2,4,6}          — PROTOCOL_ERROR clause
#
# All greps are scoped to the respective Step region of SKILL.md to prevent
# false positives from unrelated content elsewhere in the file.
#
# Usage: bash tests/scripts/test-loop-touchpoint-implplan-steps.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
IMPLPLAN_SKILL="$DSO_PLUGIN_DIR/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-loop-touchpoint-implplan-steps.sh ==="
echo ""

# ── Section extractors ────────────────────────────────────────────────────────
# Each extractor scopes output to the named step heading through the next
# same-level '## ' heading, preventing false positives from other sections.

_step2_section() {
  awk '/^## Step 2:/{found=1} found && /^## / && !/^## Step 2:/{exit} found{print}' "$IMPLPLAN_SKILL"
}

_step4_section() {
  awk '/^## Step 4:/{found=1} found && /^## / && !/^## Step 4:/{exit} found{print}' "$IMPLPLAN_SKILL"
}

_step6_section() {
  awk '/^## Step 6:/{found=1} found && /^## / && !/^## Step 6:/{exit} found{print}' "$IMPLPLAN_SKILL"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
# _assert_cycle_declaration <label> <section_text>
_assert_cycle_declaration() {
  local label="$1" section="$2"
  local _found=0
  [[ "$section" == *"Current cycle: N of MAX_CYCLES"* ]] && _found=1
  assert_eq "${label}: 'Current cycle: N of MAX_CYCLES' present" "1" "$_found"
}

# _assert_oscillation_check_gate <label> <section_text>
_assert_oscillation_check_gate() {
  local label="$1" section="$2"
  local _has_osc_check=0 _has_cycle_gate=0
  [[ "$section" == *"oscillation-check"* ]] && _has_osc_check=1
  [[ "$section" =~ (cycle[[:space:]]*>[=][[:space:]]*2|N[[:space:]]*>[=][[:space:]]*2|cycle.*2.*gate|gate.*cycle.*2) ]] && _has_cycle_gate=1
  assert_eq "${label}: 'oscillation-check' present" "1" "$_has_osc_check"
  assert_eq "${label}: cycle >= 2 gate language present" "1" "$_has_cycle_gate"
}

# _assert_halt_vs_replan_exclusivity <label> <section_text>
_assert_halt_vs_replan_exclusivity() {
  local label="$1" section="$2"
  local _has_exclusivity=0
  [[ "$section" == *"HALT-vs-REPLAN"* ]] && _has_exclusivity=1
  assert_eq "${label}: HALT-vs-REPLAN exclusivity language present" "1" "$_has_exclusivity"
}

# _assert_terminal_replan_escalate <label> <section_text>
_assert_terminal_replan_escalate() {
  local label="$1" section="$2"
  local _has_replan_escalate=0
  # Match REPLAN_ESCALATE: planner_supplied (with optional space after colon)
  [[ "$section" =~ REPLAN_ESCALATE:[[:space:]]?planner_supplied ]] && _has_replan_escalate=1
  assert_eq "${label}: REPLAN_ESCALATE: planner_supplied present" "1" "$_has_replan_escalate"
}

# _assert_mid_loop_success_exit <label> <section_text>
_assert_mid_loop_success_exit() {
  local label="$1" section="$2"
  local _has_success_exit=0
  local _lower="${section,,}"
  [[ "$_lower" =~ (success.*exit|exit.*success|empty.*finding.*exit|exit.*empty.*finding|loop.*exit.*proceed|proceed.*step|passes.*on.*any.*cycle|any.*cycle.*exits) ]] && _has_success_exit=1
  assert_eq "${label}: mid-loop success exit language present" "1" "$_has_success_exit"
}

# _assert_protocol_error <label> <section_text>
_assert_protocol_error() {
  local label="$1" section="$2"
  local _has_protocol_error=0
  [[ "$section" == *"PROTOCOL_ERROR"* ]] && _has_protocol_error=1
  assert_eq "${label}: PROTOCOL_ERROR clause present" "1" "$_has_protocol_error"
}

# ── Step 2 tests ──────────────────────────────────────────────────────────────

test_cycle_declaration_step2() {
  _snapshot_fail
  local _section
  _section=$(_step2_section)
  _assert_cycle_declaration "test_cycle_declaration_step2" "$_section"
  assert_pass_if_clean "test_cycle_declaration_step2"
}

test_oscillation_check_gate_step2() {
  _snapshot_fail
  local _section
  _section=$(_step2_section)
  _assert_oscillation_check_gate "test_oscillation_check_gate_step2" "$_section"
  assert_pass_if_clean "test_oscillation_check_gate_step2"
}

test_halt_vs_replan_exclusivity_step2() {
  _snapshot_fail
  local _section
  _section=$(_step2_section)
  _assert_halt_vs_replan_exclusivity "test_halt_vs_replan_exclusivity_step2" "$_section"
  assert_pass_if_clean "test_halt_vs_replan_exclusivity_step2"
}

test_terminal_replan_escalate_step2() {
  _snapshot_fail
  local _section
  _section=$(_step2_section)
  _assert_terminal_replan_escalate "test_terminal_replan_escalate_step2" "$_section"
  assert_pass_if_clean "test_terminal_replan_escalate_step2"
}

test_mid_loop_success_exit_step2() {
  _snapshot_fail
  local _section
  _section=$(_step2_section)
  _assert_mid_loop_success_exit "test_mid_loop_success_exit_step2" "$_section"
  assert_pass_if_clean "test_mid_loop_success_exit_step2"
}

test_protocol_error_step2() {
  _snapshot_fail
  local _section
  _section=$(_step2_section)
  _assert_protocol_error "test_protocol_error_step2" "$_section"
  assert_pass_if_clean "test_protocol_error_step2"
}

# ── Step 4 tests ──────────────────────────────────────────────────────────────

test_cycle_declaration_step4() {
  _snapshot_fail
  local _section
  _section=$(_step4_section)
  _assert_cycle_declaration "test_cycle_declaration_step4" "$_section"
  assert_pass_if_clean "test_cycle_declaration_step4"
}

test_oscillation_check_gate_step4() {
  _snapshot_fail
  local _section
  _section=$(_step4_section)
  _assert_oscillation_check_gate "test_oscillation_check_gate_step4" "$_section"
  assert_pass_if_clean "test_oscillation_check_gate_step4"
}

test_halt_vs_replan_exclusivity_step4() {
  _snapshot_fail
  local _section
  _section=$(_step4_section)
  _assert_halt_vs_replan_exclusivity "test_halt_vs_replan_exclusivity_step4" "$_section"
  assert_pass_if_clean "test_halt_vs_replan_exclusivity_step4"
}

test_terminal_replan_escalate_step4() {
  _snapshot_fail
  local _section
  _section=$(_step4_section)
  _assert_terminal_replan_escalate "test_terminal_replan_escalate_step4" "$_section"
  assert_pass_if_clean "test_terminal_replan_escalate_step4"
}

test_mid_loop_success_exit_step4() {
  _snapshot_fail
  local _section
  _section=$(_step4_section)
  _assert_mid_loop_success_exit "test_mid_loop_success_exit_step4" "$_section"
  assert_pass_if_clean "test_mid_loop_success_exit_step4"
}

test_protocol_error_step4() {
  _snapshot_fail
  local _section
  _section=$(_step4_section)
  _assert_protocol_error "test_protocol_error_step4" "$_section"
  assert_pass_if_clean "test_protocol_error_step4"
}

# ── Step 6 tests ──────────────────────────────────────────────────────────────

test_cycle_declaration_step6() {
  _snapshot_fail
  local _section
  _section=$(_step6_section)
  _assert_cycle_declaration "test_cycle_declaration_step6" "$_section"
  assert_pass_if_clean "test_cycle_declaration_step6"
}

test_oscillation_check_gate_step6() {
  _snapshot_fail
  local _section
  _section=$(_step6_section)
  _assert_oscillation_check_gate "test_oscillation_check_gate_step6" "$_section"
  assert_pass_if_clean "test_oscillation_check_gate_step6"
}

test_halt_vs_replan_exclusivity_step6() {
  _snapshot_fail
  local _section
  _section=$(_step6_section)
  _assert_halt_vs_replan_exclusivity "test_halt_vs_replan_exclusivity_step6" "$_section"
  assert_pass_if_clean "test_halt_vs_replan_exclusivity_step6"
}

test_terminal_replan_escalate_step6() {
  _snapshot_fail
  local _section
  _section=$(_step6_section)
  _assert_terminal_replan_escalate "test_terminal_replan_escalate_step6" "$_section"
  assert_pass_if_clean "test_terminal_replan_escalate_step6"
}

test_mid_loop_success_exit_step6() {
  _snapshot_fail
  local _section
  _section=$(_step6_section)
  _assert_mid_loop_success_exit "test_mid_loop_success_exit_step6" "$_section"
  assert_pass_if_clean "test_mid_loop_success_exit_step6"
}

test_protocol_error_step6() {
  _snapshot_fail
  local _section
  _section=$(_step6_section)
  _assert_protocol_error "test_protocol_error_step6" "$_section"
  assert_pass_if_clean "test_protocol_error_step6"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "--- Step 2: Consistency & Architectural Review ---"
test_cycle_declaration_step2
test_oscillation_check_gate_step2
test_halt_vs_replan_exclusivity_step2
test_terminal_replan_escalate_step2
test_mid_loop_success_exit_step2
test_protocol_error_step2

echo ""
echo "--- Step 4: Implementation Plan Review ---"
test_cycle_declaration_step4
test_oscillation_check_gate_step4
test_halt_vs_replan_exclusivity_step4
test_terminal_replan_escalate_step4
test_mid_loop_success_exit_step4
test_protocol_error_step4

echo ""
echo "--- Step 6: Gap Analysis ---"
test_cycle_declaration_step6
test_oscillation_check_gate_step6
test_halt_vs_replan_exclusivity_step6
test_terminal_replan_escalate_step6
test_mid_loop_success_exit_step6
test_protocol_error_step6

print_summary
