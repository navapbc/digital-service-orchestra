#!/usr/bin/env bash
# tests/scripts/test-debug-everything-escalation.sh
# RED tests: verify debug-everything SKILL.md has Phase 2.5 removed and escalation handling added.
#
# TDD RED phase: all 3 tests FAIL until the GREEN story (w21-b0tq) removes Phase 2.5
# from debug-everything and adds escalation handling for COMPLEX bugs from fix-bug.
#
# Usage: bash tests/scripts/test-debug-everything-escalation.sh
# Returns: exit 0 if all tests pass, exit 1 otherwise

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
DEBUG_EVERYTHING_SKILL="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

PASS=0
FAIL=0

echo "=== test-debug-everything-escalation.sh ==="
echo ""

# ── test_no_phase_2_5 ─────────────────────────────────────────────────────────
# Verify debug-everything SKILL.md does NOT contain 'Phase 2.5: Complexity Gate'
# RED: FAIL because SKILL.md still has the Phase 2.5 section.
echo "Test: test_no_phase_2_5"
if grep -q "Phase 2.5: Complexity Gate" "$DEBUG_EVERYTHING_SKILL"; then
  echo "  FAIL: debug-everything SKILL.md still contains 'Phase 2.5: Complexity Gate'" >&2
  echo "        Expected it to be removed (story w21-b0tq)" >&2
  (( FAIL++ ))
else
  echo "  PASS: debug-everything SKILL.md does not contain 'Phase 2.5: Complexity Gate'"
  (( PASS++ ))
fi
echo ""

# ── test_escalation_handling_present ─────────────────────────────────────────
# Verify SKILL.md contains escalation report handling with 're-dispatch' or 'orchestrator' references
# relevant to COMPLEX bug escalation from fix-bug.
# RED: FAIL because SKILL.md does not yet have the new escalation-from-fix-bug handling section.
echo "Test: test_escalation_handling_present"
if grep -q "COMPLEX_ESCALATION\|complex.*escalat\|escalat.*COMPLEX\|fix-bug.*escalat\|escalat.*fix-bug" "$DEBUG_EVERYTHING_SKILL"; then
  echo "  PASS: debug-everything SKILL.md contains escalation report handling for COMPLEX bugs from fix-bug"
  (( PASS++ ))
else
  echo "  FAIL: debug-everything SKILL.md missing escalation handling (re-dispatch/orchestrator) for COMPLEX bugs from fix-bug" >&2
  echo "        Expected references to COMPLEX escalation from fix-bug (story w21-b0tq)" >&2
  (( FAIL++ ))
fi
echo ""

# ── test_no_phase_2_5_dispatch_ref ───────────────────────────────────────────
# Verify the dispatch template in SKILL.md does NOT reference 'Phase 2.5 complexity gate'
# RED: FAIL because SKILL.md still has 'Phase 2.5 complexity gate' in the sub-agent prompt template.
echo "Test: test_no_phase_2_5_dispatch_ref"
if grep -q "Phase 2.5 complexity gate" "$DEBUG_EVERYTHING_SKILL"; then
  echo "  FAIL: debug-everything SKILL.md dispatch template still references 'Phase 2.5 complexity gate'" >&2
  echo "        Expected it to be removed from the sub-agent prompt template (story w21-b0tq)" >&2
  (( FAIL++ ))
else
  echo "  PASS: debug-everything SKILL.md dispatch template does not reference 'Phase 2.5 complexity gate'"
  (( PASS++ ))
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAIL ($FAIL test(s) failed)"
  exit 1
else
  echo "RESULT: PASS (all tests passed)"
  exit 0
fi
