---
id: w21-gljg
status: closed
deps: []
links: []
created: 2026-03-20T01:05:54Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-25vk
---
# RED: Tests for debug-everything Phase 2.5 removal + escalation handling


## Notes

**2026-03-20T01:06:19Z**

## Description
Create tests/scripts/test-debug-everything-escalation.sh with 3 tests:
1. test_no_phase_2_5 — verify debug-everything SKILL.md does NOT contain 'Phase 2.5: Complexity Gate'
2. test_escalation_handling_present — verify SKILL.md contains escalation report handling with 're-dispatch' or 'orchestrator' references
3. test_no_phase_2_5_dispatch_ref — verify dispatch template does NOT reference 'Phase 2.5 complexity gate'
All 3 FAIL (RED).

TDD: These ARE the RED tests.

## File Impact
- tests/scripts/test-debug-everything-escalation.sh (create — new test file with 3 test functions)

## ACCEPTANCE CRITERIA
- [ ] Test file tests/scripts/test-debug-everything-escalation.sh exists
  Verify: test -f tests/scripts/test-debug-everything-escalation.sh
- [ ] Test file contains test_no_phase_2_5 function
  Verify: grep -q 'test_no_phase_2_5' tests/scripts/test-debug-everything-escalation.sh
- [ ] Test file contains test_escalation_handling_present function
  Verify: grep -q 'test_escalation_handling_present' tests/scripts/test-debug-everything-escalation.sh
- [ ] Test file contains test_no_phase_2_5_dispatch_ref function
  Verify: grep -q 'test_no_phase_2_5_dispatch_ref' tests/scripts/test-debug-everything-escalation.sh
- [ ] All 3 tests FAIL (RED) because debug-everything SKILL.md still contains Phase 2.5
  Verify: bash tests/scripts/test-debug-everything-escalation.sh 2>&1 | grep -c FAIL | { read c; test "$c" -ge 3; }

**2026-03-20T01:21:42Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T01:22:23Z**

CHECKPOINT 2/6: Code patterns understood ✓ — bash test files use set -uo pipefail, SCRIPT_DIR/PLUGIN_ROOT/DSO_PLUGIN_DIR setup, PASS/FAIL/PENDING counters, test case groups with PASS/FAIL/PENDING results, summary block with exit 0/1. debug-everything SKILL.md has Phase 2.5 section at line 289 and escalation-related prose (re-dispatch, orchestrator refs) at lines 668-750.

**2026-03-20T01:23:19Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T01:23:25Z**

CHECKPOINT 4/6: Implementation complete ✓ — test file created at tests/scripts/test-debug-everything-escalation.sh with 3 test functions

**2026-03-20T01:23:39Z**

CHECKPOINT 5/6: Validation passed ✓ — all 3 tests FAIL (RED) as expected: test_no_phase_2_5, test_escalation_handling_present, test_no_phase_2_5_dispatch_ref

**2026-03-20T01:23:56Z**

CHECKPOINT 6/6: Done ✓ — all 5 AC verified: test file exists, 3 test functions present, all 3 tests FAIL (RED) as required for TDD
