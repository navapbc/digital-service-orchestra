#!/usr/bin/env bash
# tests/scripts/test-loop-touchpoint-sprint-verifier-fail.sh
# Behavioral fixture: verify sprint/SKILL.md planner-dispatch-story-level HARD-GATE
# contains the shared remediation loop protocol block (all 7 DD scenarios) with
# dynamic upstream sourcing from the planner's escalation_upstream field.
#
# Tests (7 DD scenarios):
#  1. test_cycle_declaration              — grep for 'Current cycle: N of MAX_CYCLES'
#  2. test_oscillation_check_gate         — grep for oscillation-check + cycle >= 2 gate
#  3. test_halt_vs_replan_exclusivity     — grep for HALT-vs-REPLAN exclusivity language
#  4. test_terminal_replan_escalate_dynamic — REPLAN_ESCALATE: prefix present AND
#                                            escalation_upstream keyword present (proves
#                                            dynamic source, not hardcoded upstream value)
#  5. test_mid_loop_success_exit          — grep for mid-loop success exit language
#  6. test_protocol_error                 — grep for PROTOCOL_ERROR
#  7. test_protocol_doc_pointer           — grep for See: ... remediation-loop-protocol.md
#
# All greps are scoped to the planner-dispatch-story-level HARD-GATE block in
# sprint/SKILL.md to prevent false positives from unrelated content elsewhere.
#
# Key distinction from other touchpoints (preplanning/implplan):
#   The REPLAN_ESCALATE upstream for sprint verifier-fail is NOT hardcoded
#   (unlike 'brainstorm' for preplanning or 'planner_supplied' for implplan).
#   Instead, it is sourced DYNAMICALLY from the planner's escalation_upstream
#   field (${CLAUDE_PLUGIN_ROOT}/agents/verification-remediation-planner.md).
#   test_terminal_replan_escalate_dynamic asserts the keyword 'escalation_upstream'
#   appears in the block (proving the block documents dynamic sourcing).
#
# Usage: bash tests/scripts/test-loop-touchpoint-sprint-verifier-fail.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
SPRINT_SKILL="$DSO_PLUGIN_DIR/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-loop-touchpoint-sprint-verifier-fail.sh ==="
echo ""

# ── Extract the planner-dispatch-story-level HARD-GATE section ───────────────
# Scope all assertions to the block delimited by
#   <HARD-GATE id="planner-dispatch-story-level"> ... </HARD-GATE>
# This is the canonical f63c re-dispatch block in Phase F Step 18.
# Using the unique HARD-GATE id prevents false positives from the epic-level
# gate (planner-dispatch-epic-level) or other REPLAN_ESCALATE references.
_story_level_gate_section() {
  awk '/HARD-GATE id="planner-dispatch-story-level"/{found=1} found && /^<\/HARD-GATE>/{print; exit} found{print}' "$SPRINT_SKILL"
}

# ── test_cycle_declaration ────────────────────────────────────────────────────
# Verify the sprint verifier-fail loop block declares 'Current cycle: N of
# MAX_CYCLES' per-cycle. Machine-parseable hook required by protocol Section 1.
test_cycle_declaration() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _found=0
  [[ "$_section" == *"Current cycle: N of MAX_CYCLES"* ]] && _found=1
  assert_eq "test_cycle_declaration: 'Current cycle: N of MAX_CYCLES' present in story-level gate" \
    "1" "$_found"
  assert_pass_if_clean "test_cycle_declaration"
}

# ── test_oscillation_check_gate ───────────────────────────────────────────────
# Verify the block mandates the oscillation-check Skill hard gate on cycle >= 2.
# Both 'oscillation-check' and cycle >= 2 language must appear.
test_oscillation_check_gate() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _has_osc_check=0 _has_cycle_gate=0
  [[ "$_section" == *"oscillation-check"* ]] && _has_osc_check=1
  # Accept 'cycle >= 2', 'N >= 2', or equivalent phrasing
  [[ "$_section" =~ (cycle[[:space:]]*>[=][[:space:]]*2|N[[:space:]]*>[=][[:space:]]*2|cycle.*2.*gate|gate.*cycle.*2) ]] && _has_cycle_gate=1
  assert_eq "test_oscillation_check_gate: 'oscillation-check' present in story-level gate" \
    "1" "$_has_osc_check"
  assert_eq "test_oscillation_check_gate: cycle >= 2 gate language present in story-level gate" \
    "1" "$_has_cycle_gate"
  assert_pass_if_clean "test_oscillation_check_gate"
}

# ── test_halt_vs_replan_exclusivity ──────────────────────────────────────────
# Verify the block documents the HALT-vs-REPLAN exclusivity invariant:
# REPLAN_ESCALATE only when cycle_count == MAX_CYCLES AND findings non-empty;
# other states emit different tokens.
test_halt_vs_replan_exclusivity() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _has_exclusivity=0
  [[ "$_section" == *"HALT-vs-REPLAN"* ]] && _has_exclusivity=1
  assert_eq "test_halt_vs_replan_exclusivity: HALT-vs-REPLAN exclusivity language present in story-level gate" \
    "1" "$_has_exclusivity"
  assert_pass_if_clean "test_halt_vs_replan_exclusivity"
}

# ── test_terminal_replan_escalate_dynamic ────────────────────────────────────
# Verify the block documents REPLAN_ESCALATE with DYNAMIC upstream sourcing.
# Two sub-checks:
#   (a) 'REPLAN_ESCALATE: ' prefix present (canonical colon-space format)
#   (b) 'escalation_upstream' keyword present (proves block references the
#       planner's field as the dynamic source, not a hardcoded enum value)
# This test is the key distinction from preplanning (brainstorm) and implplan
# (planner_supplied) — the sprint verifier-fail touchpoint reads upstream
# from the planner's escalation_upstream field at runtime.
test_terminal_replan_escalate_dynamic() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _has_replan_prefix=0 _has_dynamic_source=0
  # Check canonical REPLAN_ESCALATE: prefix (colon-space)
  [[ "$_section" == *"REPLAN_ESCALATE: "* ]] && _has_replan_prefix=1
  # Check 'escalation_upstream' keyword — proves dynamic source, not hardcoded
  [[ "$_section" == *"escalation_upstream"* ]] && _has_dynamic_source=1
  assert_eq "test_terminal_replan_escalate_dynamic: 'REPLAN_ESCALATE: ' prefix present in story-level gate" \
    "1" "$_has_replan_prefix"
  assert_eq "test_terminal_replan_escalate_dynamic: 'escalation_upstream' keyword present (dynamic source)" \
    "1" "$_has_dynamic_source"
  assert_pass_if_clean "test_terminal_replan_escalate_dynamic"
}

# ── test_mid_loop_success_exit ────────────────────────────────────────────────
# Verify the block documents that success on any cycle exits the loop
# immediately (before reaching MAX_CYCLES). Protocol Section 2.
test_mid_loop_success_exit() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _has_success_exit=0
  # Accept any phrasing that conveys success-on-any-cycle exits the loop
  [[ "${_section,,}" =~ (success.*exit|exit.*success|empty.*finding.*exit|exit.*empty.*finding|loop.*exit.*proceed|loop exits immediately|p1.*pass.*exits|pass.*any.*cycle) ]] && _has_success_exit=1
  assert_eq "test_mid_loop_success_exit: mid-loop success exit language present in story-level gate" \
    "1" "$_has_success_exit"
  assert_pass_if_clean "test_mid_loop_success_exit"
}

# ── test_protocol_error ───────────────────────────────────────────────────────
# Verify the block documents PROTOCOL_ERROR as the token for illegal state
# transitions (invariant violations). Protocol Section 2.4.
test_protocol_error() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _has_protocol_error=0
  [[ "$_section" == *"PROTOCOL_ERROR"* ]] && _has_protocol_error=1
  assert_eq "test_protocol_error: PROTOCOL_ERROR token present in story-level gate" \
    "1" "$_has_protocol_error"
  assert_pass_if_clean "test_protocol_error"
}

# ── test_protocol_doc_pointer ─────────────────────────────────────────────────
# Verify the block includes a trailing pointer to the shared protocol doc
# (remediation-loop-protocol.md). This anchors the block to the canonical spec.
test_protocol_doc_pointer() {
  _snapshot_fail
  local _section
  _section=$(_story_level_gate_section)
  local _has_pointer=0
  [[ "$_section" == *"remediation-loop-protocol.md"* ]] && _has_pointer=1
  assert_eq "test_protocol_doc_pointer: 'remediation-loop-protocol.md' pointer present in story-level gate" \
    "1" "$_has_pointer"
  assert_pass_if_clean "test_protocol_doc_pointer"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_cycle_declaration
test_oscillation_check_gate
test_halt_vs_replan_exclusivity
test_terminal_replan_escalate_dynamic
test_mid_loop_success_exit
test_protocol_error
test_protocol_doc_pointer

print_summary
