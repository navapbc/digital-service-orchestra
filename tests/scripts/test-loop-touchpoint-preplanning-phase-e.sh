#!/usr/bin/env bash
# tests/scripts/test-loop-touchpoint-preplanning-phase-e.sh
# Behavioral fixture: verify preplanning/SKILL.md Phase E contains the shared
# remediation loop protocol block (all 6 DD scenarios).
#
# Tests (6 DD scenarios):
#  1. test_cycle_declaration       — grep for 'Current cycle: N of MAX_CYCLES'
#  2. test_oscillation_check_gate  — grep for oscillation-check and cycle >= 2 gate
#  3. test_halt_vs_replan_exclusivity — grep for HALT-vs-REPLAN exclusivity language
#  4. test_terminal_replan_escalate — grep for REPLAN_ESCALATE:brainstorm
#  5. test_mid_loop_success_exit   — grep for mid-loop success exit language
#  6. test_protocol_error          — grep for PROTOCOL_ERROR
#
# All greps are scoped to the Phase E + b345 loop block region of SKILL.md
# to prevent false positives from unrelated content elsewhere in the file.
#
# Usage: bash tests/scripts/test-loop-touchpoint-preplanning-phase-e.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PREPLANNING_SKILL="$DSO_PLUGIN_DIR/skills/preplanning/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-loop-touchpoint-preplanning-phase-e.sh ==="
echo ""

# ── Extract Phase E section ───────────────────────────────────────────────────
# Scope all assertions to Phase E (from '## Phase E' heading to the next
# '## ' heading), preventing false positives from pre-existing content elsewhere.
_phase_e_section() {
  awk '/^## Phase E:/{found=1} found && /^## / && !/^## Phase E:/{exit} found{print}' "$PREPLANNING_SKILL"
}

# ── test_cycle_declaration ────────────────────────────────────────────────────
# Verify Phase E loop block declares 'Current cycle: N of MAX_CYCLES' per-cycle.
# This is the machine-parseable hook required by protocol Section 1.
test_cycle_declaration() {
  _snapshot_fail
  local _section
  _section=$(_phase_e_section)
  local _found=0
  [[ "$_section" == *"Current cycle: N of MAX_CYCLES"* ]] && _found=1
  assert_eq "test_cycle_declaration: 'Current cycle: N of MAX_CYCLES' present in Phase E" \
    "1" "$_found"
  assert_pass_if_clean "test_cycle_declaration"
}

# ── test_oscillation_check_gate ───────────────────────────────────────────────
# Verify Phase E loop block mandates the oscillation-check Skill hard gate on
# cycle >= 2. Both 'oscillation-check' and cycle >= 2 language must appear.
test_oscillation_check_gate() {
  _snapshot_fail
  local _section
  _section=$(_phase_e_section)
  local _has_osc_check=0 _has_cycle_gate=0
  [[ "$_section" == *"oscillation-check"* ]] && _has_osc_check=1
  # Accept 'cycle >= 2', 'N >= 2', or equivalent phrasing
  [[ "$_section" =~ (cycle[[:space:]]*>[=][[:space:]]*2|N[[:space:]]*>[=][[:space:]]*2|cycle.*2.*gate|gate.*cycle.*2) ]] && _has_cycle_gate=1
  assert_eq "test_oscillation_check_gate: 'oscillation-check' present in Phase E" \
    "1" "$_has_osc_check"
  assert_eq "test_oscillation_check_gate: cycle >= 2 gate language present in Phase E" \
    "1" "$_has_cycle_gate"
  assert_pass_if_clean "test_oscillation_check_gate"
}

# ── test_halt_vs_replan_exclusivity ──────────────────────────────────────────
# Verify Phase E loop block documents the HALT-vs-REPLAN exclusivity invariant:
# REPLAN_ESCALATE only when cycle_count == MAX_CYCLES AND findings non-empty;
# other states emit different tokens.
test_halt_vs_replan_exclusivity() {
  _snapshot_fail
  local _section
  _section=$(_phase_e_section)
  local _has_exclusivity=0
  # Check for HALT-vs-REPLAN exclusivity language (the block uses this exact phrase)
  [[ "$_section" == *"HALT-vs-REPLAN"* ]] && _has_exclusivity=1
  assert_eq "test_halt_vs_replan_exclusivity: HALT-vs-REPLAN exclusivity language present in Phase E" \
    "1" "$_has_exclusivity"
  assert_pass_if_clean "test_halt_vs_replan_exclusivity"
}

# ── test_terminal_replan_escalate ─────────────────────────────────────────────
# Verify Phase E loop block specifies REPLAN_ESCALATE:brainstorm as the terminal
# token on cycle MAX_CYCLES failure. The upstream enum value is 'brainstorm'
# for preplanning Phase E (Section 6 of remediation-loop-protocol.md).
test_terminal_replan_escalate() {
  _snapshot_fail
  local _section
  _section=$(_phase_e_section)
  local _has_replan_escalate=0
  # Match REPLAN_ESCALATE:brainstorm (with optional space after colon)
  [[ "$_section" =~ REPLAN_ESCALATE:[[:space:]]?brainstorm ]] && _has_replan_escalate=1
  assert_eq "test_terminal_replan_escalate: REPLAN_ESCALATE:brainstorm present in Phase E" \
    "1" "$_has_replan_escalate"
  assert_pass_if_clean "test_terminal_replan_escalate"
}

# ── test_mid_loop_success_exit ────────────────────────────────────────────────
# Verify Phase E loop block documents that success on any cycle exits the loop
# immediately (before reaching MAX_CYCLES). This is the 'mid-loop success exit'
# behavior from protocol Section 2.
test_mid_loop_success_exit() {
  _snapshot_fail
  local _section
  _section=$(_phase_e_section)
  local _has_success_exit=0
  # Accept any phrasing that conveys success-on-any-cycle exits the loop
  [[ "${_section,,}" =~ (success.*exit|exit.*success|empty.*finding.*exit|exit.*empty.*finding|loop.*exit.*proceed|proceed.*phase.f) ]] && _has_success_exit=1
  assert_eq "test_mid_loop_success_exit: mid-loop success exit language present in Phase E" \
    "1" "$_has_success_exit"
  assert_pass_if_clean "test_mid_loop_success_exit"
}

# ── test_protocol_error ───────────────────────────────────────────────────────
# Verify Phase E loop block documents PROTOCOL_ERROR as the token for illegal
# state transitions (invariant violations). This is protocol Section 2.4.
test_protocol_error() {
  _snapshot_fail
  local _section
  _section=$(_phase_e_section)
  local _has_protocol_error=0
  [[ "$_section" == *"PROTOCOL_ERROR"* ]] && _has_protocol_error=1
  assert_eq "test_protocol_error: PROTOCOL_ERROR token present in Phase E" \
    "1" "$_has_protocol_error"
  assert_pass_if_clean "test_protocol_error"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_cycle_declaration
test_oscillation_check_gate
test_halt_vs_replan_exclusivity
test_terminal_replan_escalate
test_mid_loop_success_exit
test_protocol_error

print_summary
