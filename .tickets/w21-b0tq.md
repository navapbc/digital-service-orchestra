---
id: w21-b0tq
status: closed
deps: [w21-gljg]
links: []
created: 2026-03-20T01:05:55Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-25vk
---
# GREEN: Remove Phase 2.5 from debug-everything + add escalation handling


## Notes

**2026-03-20T01:06:24Z**

## Description
Edit plugins/dso/skills/debug-everything/SKILL.md:
1. Remove Phase 2.5: Complexity Gate section entirely (Steps 1-5)
2. Remove 'Complexity (from Phase 2.5 complexity gate)' reference from sub-agent dispatch template
3. Add escalation report handling in Phase 6 (Post-Batch Checkpoint) — after fix-bug sub-agents return, parse each result for escalation signals; if escalation detected, re-dispatch that bug at orchestrator level (direct /dso:fix-bug invocation, not sub-agent)

TDD: Task w21-gljg RED tests turn GREEN after this implementation.

## File Impact
- plugins/dso/skills/debug-everything/SKILL.md (modify — remove Phase 2.5, add escalation handling)

## ACCEPTANCE CRITERIA
- [ ] debug-everything SKILL.md does NOT contain 'Phase 2.5: Complexity Gate'
  Verify: { grep -q 'Phase 2.5: Complexity Gate' plugins/dso/skills/debug-everything/SKILL.md; test $? -ne 0; }
- [ ] debug-everything SKILL.md contains escalation handling with 're-dispatch' or 'orchestrator' references
  Verify: grep -qE '(re-dispatch|orchestrator.*escalat|escalat.*orchestrator)' plugins/dso/skills/debug-everything/SKILL.md
- [ ] dispatch template does NOT reference 'Phase 2.5 complexity gate'
  Verify: { grep -qi 'Phase 2.5 complexity gate' plugins/dso/skills/debug-everything/SKILL.md; test $? -ne 0; }
- [ ] RED tests from w21-gljg now pass (GREEN)
  Verify: bash tests/scripts/test-debug-everything-escalation.sh 2>&1 | grep -q 'RESULT: PASS'

**2026-03-20T01:31:44Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T01:32:36Z**

CHECKPOINT 2/6: Code patterns understood ✓ — Phase 2.5 is at lines 289-373, dispatch template 'Complexity (from Phase 2.5 complexity gate)' is at line 615, and Phase 6 Post-Batch Checkpoint starts at line 662. Need to: remove Phase 2.5 section (lines 289-373), update dispatch template to remove complexity line and Phase 2.5 reference, update orchestration flow, add escalation handling to Phase 6, and update Phase 10 summary section.

**2026-03-20T01:32:43Z**

CHECKPOINT 3/6: Tests written (pre-existing RED tests) ✓ — Tests check: (1) no 'Phase 2.5: Complexity Gate', (2) escalation handling with COMPLEX_ESCALATION/complex.*escalat/escalat.*COMPLEX/fix-bug.*escalat/escalat.*fix-bug references, (3) no 'Phase 2.5 complexity gate' in dispatch template.

**2026-03-20T01:34:48Z**

CHECKPOINT 4/6: Implementation complete ✓ — (1) Removed Phase 2.5 section entirely, (2) Updated orchestration flow to skip Phase 2.5, (3) Removed 'Complexity (from Phase 2.5 complexity gate)' from dispatch template, (4) Added Step 3a COMPLEX Escalation Handling to Phase 6, (5) Updated Phase 10 summary to reference fix-bug escalations.

**2026-03-20T01:34:54Z**

CHECKPOINT 5/6: Validation passed ✓ — all 3 tests PASS: test_no_phase_2_5, test_escalation_handling_present, test_no_phase_2_5_dispatch_ref

**2026-03-20T01:35:10Z**

CHECKPOINT 6/6: Done ✓ — All 4 AC verify commands pass. AC1: no Phase 2.5 heading, AC2: escalation handling present, AC3: no Phase 2.5 dispatch ref, AC4: test suite PASS.
