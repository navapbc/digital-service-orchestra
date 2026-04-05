#!/usr/bin/env bash
# tests/scripts/test-implementation-plan-resolution-loop.sh
# RED tests: verify implementation-plan SKILL.md has resolution loop section structure.
#
# TDD RED phase: all 6 tests FAIL until the GREEN story adds the
# ### Resolution Loop section to implementation-plan SKILL.md.
#
# Tests:
#  1. test_resolution_loop_section_exists  — grep for '### Resolution Loop' heading
#  2. test_accept_revise_escalate          — awk-scoped to Resolution Loop section,
#                                            grep for accept, revise, and escalate keywords
#  3. test_cycle_bound                     — awk-scoped to Resolution Loop section,
#                                            grep for "2 cycles" or "max.*2" cycle limit
#  4. test_state_file_persistence          — awk-scoped to Resolution Loop section,
#                                            grep for "/tmp/approach-resolution" state file reference
#  5. test_user_escalation                 — awk-scoped to Resolution Loop section,
#                                            grep for user escalation after cycle limit
#  6. test_decision_maker_dispatch         — awk-scoped to Resolution Loop section,
#                                            grep for "approach-decision-maker" agent reference
#
# Usage: bash tests/scripts/test-implementation-plan-resolution-loop.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
IMPL_PLAN_SKILL="$DSO_PLUGIN_DIR/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-resolution-loop.sh ==="
echo ""

# ── test_resolution_loop_section_exists ──────────────────────────────────────
# Verify implementation-plan SKILL.md contains '### Resolution Loop' heading.
# RED: FAIL because SKILL.md does not yet have this section.
test_resolution_loop_section_exists() {
  _snapshot_fail
  local _found=0
  grep -q "### Resolution Loop" "$IMPL_PLAN_SKILL" && _found=1
  assert_eq "test_resolution_loop_section_exists: '### Resolution Loop' heading present" \
    "1" "$_found"
  assert_pass_if_clean "test_resolution_loop_section_exists"
}

# ── test_accept_revise_escalate ───────────────────────────────────────────────
# Verify SKILL.md Resolution Loop section contains accept, revise, and escalate
# outcome keywords.
# Uses awk to scope the search to the Resolution Loop section only —
# preventing false positives from pre-existing content elsewhere in SKILL.md.
# RED: FAIL because the resolution loop section does not yet exist.
test_accept_revise_escalate() {
  _snapshot_fail
  # Extract only the Resolution Loop section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Resolution Loop/{found=1} found && /^### / && !/^### Resolution Loop/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_accept=0 _has_revise=0 _has_escalate=0
  echo "$_section" | grep -qi "accept" && _has_accept=1
  echo "$_section" | grep -qi "revise" && _has_revise=1
  echo "$_section" | grep -qi "escalate" && _has_escalate=1
  assert_eq "test_accept_revise_escalate: 'accept' outcome within Resolution Loop section" \
    "1" "$_has_accept"
  assert_eq "test_accept_revise_escalate: 'revise' outcome within Resolution Loop section" \
    "1" "$_has_revise"
  assert_eq "test_accept_revise_escalate: 'escalate' outcome within Resolution Loop section" \
    "1" "$_has_escalate"
  assert_pass_if_clean "test_accept_revise_escalate"
}

# ── test_cycle_bound ──────────────────────────────────────────────────────────
# Verify SKILL.md Resolution Loop section contains a cycle limit of 2.
# Uses awk to scope the search to the Resolution Loop section only —
# preventing false positives from pre-existing numeric mentions elsewhere.
# RED: FAIL because the resolution loop section does not yet exist.
test_cycle_bound() {
  _snapshot_fail
  # Extract only the Resolution Loop section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Resolution Loop/{found=1} found && /^### / && !/^### Resolution Loop/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_cycle_bound=0
  { echo "$_section" | grep -qiE "2 cycles|max.*2|maximum.*2|cycle.*limit.*2|2.*cycle.*limit"; } && _has_cycle_bound=1
  assert_eq "test_cycle_bound: '2 cycles' or 'max.*2' cycle limit within Resolution Loop section" \
    "1" "$_has_cycle_bound"
  assert_pass_if_clean "test_cycle_bound"
}

# ── test_state_file_persistence ───────────────────────────────────────────────
# Verify SKILL.md Resolution Loop section references '/tmp/approach-resolution'
# state file for persistence across cycles.
# Uses awk to scope the search to the Resolution Loop section only —
# preventing false positives from pre-existing /tmp/ references elsewhere.
# RED: FAIL because the resolution loop section does not yet exist.
test_state_file_persistence() {
  _snapshot_fail
  # Extract only the Resolution Loop section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Resolution Loop/{found=1} found && /^### / && !/^### Resolution Loop/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_state_file=0
  echo "$_section" | grep -q "/tmp/approach-resolution" && _has_state_file=1
  assert_eq "test_state_file_persistence: '/tmp/approach-resolution' state file within Resolution Loop section" \
    "1" "$_has_state_file"
  assert_pass_if_clean "test_state_file_persistence"
}

# ── test_user_escalation ──────────────────────────────────────────────────────
# Verify SKILL.md Resolution Loop section describes user escalation behavior
# triggered after the cycle limit is reached.
# Uses awk to scope the search to the Resolution Loop section only.
# RED: FAIL because the resolution loop section does not yet exist.
test_user_escalation() {
  _snapshot_fail
  # Extract only the Resolution Loop section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Resolution Loop/{found=1} found && /^### / && !/^### Resolution Loop/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_user_escalation=0
  { echo "$_section" | grep -qiE "escalat.*user|user.*escalat|escalat.*human|human.*escalat|present.*user|user.*review"; } && _has_user_escalation=1
  assert_eq "test_user_escalation: user escalation after cycle limit within Resolution Loop section" \
    "1" "$_has_user_escalation"
  assert_pass_if_clean "test_user_escalation"
}

# ── test_decision_maker_dispatch ──────────────────────────────────────────────
# Verify SKILL.md Resolution Loop section references 'approach-decision-maker'
# agent to arbitrate proposal selection.
# Uses awk to scope the search to the Resolution Loop section only —
# preventing false positives from pre-existing agent references elsewhere.
# RED: FAIL because the resolution loop section does not yet exist.
test_decision_maker_dispatch() {
  _snapshot_fail
  # Extract only the Resolution Loop section (from heading to next ###-level heading)
  local _section
  _section=$(awk '/^### Resolution Loop/{found=1} found && /^### / && !/^### Resolution Loop/{exit} found{print}' "$IMPL_PLAN_SKILL")
  local _has_decision_maker=0
  echo "$_section" | grep -q "approach-decision-maker" && _has_decision_maker=1
  assert_eq "test_decision_maker_dispatch: 'approach-decision-maker' agent reference within Resolution Loop section" \
    "1" "$_has_decision_maker"
  assert_pass_if_clean "test_decision_maker_dispatch"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_resolution_loop_section_exists
test_accept_revise_escalate
test_cycle_bound
test_state_file_persistence
test_user_escalation
test_decision_maker_dispatch

print_summary
