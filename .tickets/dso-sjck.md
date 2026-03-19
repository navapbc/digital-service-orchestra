---
id: dso-sjck
status: closed
deps: [dso-gnbz]
links: []
created: 2026-03-19T18:36:47Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# GREEN: Create escalated-investigation-agent-2.md — History Analyst prompt (timeline reconstruction, fault tree analysis, commit bisection)

## Description

Create the History Analyst prompt template for ESCALATED investigation Agent 2.

**File to create**: `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-2.md`

**Implementation steps**:
1. Use `advanced-investigation-agent-b.md` as a structural template (History Analyst is the same role but extended for ESCALATED tier)
2. Key differences from the ADVANCED Agent B prompt:
   - Add `{escalation_history}` to the context block (with description: previous ADVANCED tier findings)
   - Update role framing to: "You are an ESCALATED-tier History Analyst. Your role is the same as ADVANCED Agent B, but you now have additional context from the previous ADVANCED investigation in `{escalation_history}`. Your goal is to identify what the previous investigation missed."
   - Update proposed_fixes requirement to "at least 3 fixes not already attempted" (from "at least 2")
   - Add a step before self-reflection: "Consult `{escalation_history}` — identify any hypotheses the ADVANCED investigation made that your timeline analysis can confirm or contradict."
   - Add read-only constraint language in the Rules section
3. Run `python -m pytest tests/skills/test_escalated_investigation_agent_2_prompt.py -q` — all tests must PASS (GREEN)

**TDD Requirement**: Tests from dso-gnbz must FAIL before this task. Run `python -m pytest tests/skills/test_escalated_investigation_agent_2_prompt.py -q` after creating; all must pass.

**Constraints**:
- `{escalation_history}` placeholder required
- Must contain `at least 3` fixes language
- Must be read-only (no source file modifications)
- Must contain `ROOT_CAUSE` and `confidence` in RESULT schema

## ACCEPTANCE CRITERIA

- [ ] All tests in `test_escalated_investigation_agent_2_prompt.py` PASS
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_escalated_investigation_agent_2_prompt.py -q 2>&1 | grep -q 'passed'
- [ ] Prompt file exists at expected path
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-2.md
- [ ] Prompt contains `{escalation_history}` placeholder
  Verify: grep -q '{escalation_history}' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-2.md
- [ ] Prompt contains ROOT_CAUSE RESULT field
  Verify: grep -q 'ROOT_CAUSE' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-2.md
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

## Notes

**2026-03-19T20:08:12Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T20:08:30Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T20:08:33Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-19T20:09:42Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T20:09:54Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-19T20:12:38Z**

CHECKPOINT 6/6: Done ✓

**2026-03-19T20:13:06Z**

CHECKPOINT 6/6: Done ✓ — 10 tests GREEN
