---
id: dso-cxuh
status: closed
deps: [dso-t28s]
links: []
created: 2026-03-19T18:36:48Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# GREEN: Create escalated-investigation-agent-3.md — Code Tracer prompt (execution path tracing, dependency-ordered reading, intermediate variable tracking, five whys)

## Description

Create the Code Tracer prompt template for ESCALATED investigation Agent 3.

**File to create**: `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-3.md`

**Implementation steps**:
1. Use `advanced-investigation-agent-a.md` as a structural template (Code Tracer is the same role but extended for ESCALATED tier)
2. Key differences from the ADVANCED Agent A prompt:
   - Add `{escalation_history}` to the context block
   - Update role framing: "You are an ESCALATED-tier Code Tracer. Your role extends ADVANCED Agent A. You have additional context from previous investigation in `{escalation_history}`. Focus on execution paths that were NOT traced in the previous investigation."
   - Add `dependency-ordered reading` as an explicit investigation step (ESCALATED adds this to the code tracer): before tracing execution, read files in dependency order (utilities/helpers first, then callers)
   - Update proposed_fixes requirement to "at least 3 fixes not already attempted"
   - Add a step consulting `{escalation_history}` before self-reflection
   - Maintain read-only constraint language in Rules section
3. Run `python -m pytest tests/skills/test_escalated_investigation_agent_3_prompt.py -q` — all tests must PASS (GREEN)

**TDD Requirement**: Tests from dso-t28s must FAIL before this task. Run `python -m pytest tests/skills/test_escalated_investigation_agent_3_prompt.py -q` after creating; all must pass.

**Constraints**:
- `{escalation_history}` placeholder required
- Must contain `dependency-ordered` reading language
- Must contain `at least 3` fixes language
- Must be read-only (no source file modifications)

## ACCEPTANCE CRITERIA

- [ ] All tests in `test_escalated_investigation_agent_3_prompt.py` PASS
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_escalated_investigation_agent_3_prompt.py -q 2>&1 | grep -q 'passed'
- [ ] Prompt file exists at expected path
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-3.md
- [ ] Prompt contains `{escalation_history}` placeholder
  Verify: grep -q '{escalation_history}' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-3.md
- [ ] Prompt contains dependency-ordered reading language
  Verify: grep -qE 'dependency-ordered|dependency ordered' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-3.md
- [ ] Prompt contains ROOT_CAUSE RESULT field
  Verify: grep -q 'ROOT_CAUSE' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-3.md
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

## Notes

**2026-03-19T19:51:57Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T19:52:12Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T19:52:16Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-19T19:53:26Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T19:53:37Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-19T19:57:15Z**

CHECKPOINT 6/6: Done ✓

**2026-03-19T19:57:38Z**

CHECKPOINT 6/6: Done ✓ — 11 tests GREEN
