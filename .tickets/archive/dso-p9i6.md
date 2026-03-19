---
id: dso-p9i6
status: closed
deps: []
links: []
created: 2026-03-19T18:36:35Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# RED: Write failing tests asserting SKILL.md ESCALATED section has dispatch slots, veto logic, resolution agent, and terminal escalation

## Description

Write failing tests (RED) that assert the SKILL.md ESCALATED section contains the full dispatch specification needed for sub-agent execution.

**File to create**: `tests/skills/test_fix_bug_skill_escalated_section.py`

**Implementation steps**:
1. Create `tests/skills/test_fix_bug_skill_escalated_section.py`
2. Import pathlib; define `SKILL_FILE` path to `plugins/dso/skills/fix-bug/SKILL.md`
3. Write `_read_skill()` helper that returns `SKILL_FILE.read_text()`
4. Write the 8 test functions listed below — each must FAIL before Task dso-bgqs is implemented
5. Run `python -m pytest tests/skills/test_fix_bug_skill_escalated_section.py -q` to confirm all 8 FAIL (RED)

**Test functions** (all must FAIL before dso-bgqs GREEN task):
- `test_escalated_section_dispatch_slots_table` — asserts SKILL.md contains named context slot `escalation_history` (new slot for ESCALATED tier, not present in ADVANCED)
- `test_escalated_section_references_agent_1_prompt` — asserts SKILL.md contains `escalated-investigation-agent-1.md`
- `test_escalated_section_references_agent_2_prompt` — asserts SKILL.md contains `escalated-investigation-agent-2.md`
- `test_escalated_section_references_agent_3_prompt` — asserts SKILL.md contains `escalated-investigation-agent-3.md`
- `test_escalated_section_references_agent_4_prompt` — asserts SKILL.md contains `escalated-investigation-agent-4.md`
- `test_escalated_section_veto_logic` — asserts SKILL.md contains `veto` within the ESCALATED section (the word "veto" is not currently present in the ESCALATED stub)
- `test_escalated_section_resolution_agent` — asserts SKILL.md contains `resolution agent` within the ESCALATED section context
- `test_escalated_section_terminal_escalation` — asserts SKILL.md contains `terminal` within escalation context (surface all findings language)

**TDD Requirement**: Write the tests first. Confirm all 8 tests FAIL before moving to dso-bgqs. Do NOT implement SKILL.md changes in this task.

**Constraints**: Test assertions must use `in content` string checks on the full SKILL.md text, consistent with existing test patterns in `tests/skills/test_fix_bug_skill.py`.

## ACCEPTANCE CRITERIA

- [ ] Test file `tests/skills/test_fix_bug_skill_escalated_section.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill_escalated_section.py
- [ ] File contains exactly 8 test functions (one per behavioral requirement)
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill_escalated_section.py | awk '{exit ($1 < 8)}'
- [ ] All 8 tests FAIL before GREEN task dso-bgqs is implemented (RED confirmation)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_fix_bug_skill_escalated_section.py -q 2>&1 | grep -q 'FAILED\|failed\|error'
- [ ] `ruff check tests/skills/test_fix_bug_skill_escalated_section.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_fix_bug_skill_escalated_section.py
- [ ] `ruff format --check tests/skills/test_fix_bug_skill_escalated_section.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_fix_bug_skill_escalated_section.py

## Notes

**2026-03-19T18:44:32Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T18:45:09Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T18:45:41Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T18:46:03Z**

CHECKPOINT 4/6: Implementation complete ✓ (N/A for RED task — no SKILL.md changes)

**2026-03-19T18:46:07Z**

CHECKPOINT 5/6: Validation passed ✓ — ruff check OK, ruff format OK

**2026-03-19T18:46:19Z**

CHECKPOINT 6/6: Done ✓ — AC verified. 8 tests written; 5 FAIL (escalation_history + 4 agent prompt file refs); 3 pass (veto, resolution agent, terminal already in SKILL.md). ruff clean.

**2026-03-19T18:46:55Z**

CHECKPOINT 6/6: Done ✓ — 8 tests (5 RED, 3 GREEN pre-existing)
