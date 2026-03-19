---
id: dso-mn94
status: open
deps: [dso-6xe1]
links: []
created: 2026-03-19T18:36:38Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# GREEN: Create escalated-investigation-agent-1.md — Web Researcher prompt (error pattern analysis, similar issue correlation, dependency changelogs)

## Description

Create the Web Researcher prompt template for ESCALATED investigation Agent 1.

**File to create**: `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-1.md`

**Implementation steps**:
1. Use `advanced-investigation-agent-b.md` as a structural reference (similar context block + investigation steps + RESULT schema)
2. Create the prompt with these sections:
   - **Role framing**: "You are an opus-level Web Researcher for an ESCALATED investigation. Your lens is external knowledge: error patterns, community reports, dependency changelogs, and known issues. You are authorized to use WebSearch and WebFetch tools to research the bug from external sources."
   - **Read-only constraint**: do NOT modify source files; investigation only
   - **Context block**: `{ticket_id}`, `{failing_tests}`, `{stack_trace}`, `{commit_history}`, `{prior_fix_attempts}`, `{escalation_history}` (previous ADVANCED tier findings)
   - **Investigation steps**:
     1. Error pattern analysis — search for this exact error message or pattern online
     2. Similar issue correlation — find GitHub issues, Stack Overflow posts, or community reports matching this symptom
     3. Dependency changelog analysis — check changelogs for dependencies involved in the stack trace for breaking changes
     4. Self-reflection — does external evidence support or contradict the previous ADVANCED findings in `{escalation_history}`?
   - **RESULT schema**: ROOT_CAUSE, confidence, proposed_fixes (at least 3 fixes not already attempted), tests_run, prior_attempts, external_sources (list of URLs/references consulted)
   - **Rules section**: do not modify source files; do not implement fixes; propose only fixes not present in `{escalation_history}`; return RESULT block as final section
3. Run `python -m pytest tests/skills/test_escalated_investigation_agent_1_prompt.py -q` — all tests must PASS (GREEN)

**TDD Requirement**: Tests from dso-6xe1 must FAIL before this task. Run `python -m pytest tests/skills/test_escalated_investigation_agent_1_prompt.py -q` after creating the file; all must pass.

**Constraints**:
- `{escalation_history}` placeholder must be present in the context block
- Must contain `WebSearch` and `WebFetch` authorization language
- Must contain `at least 3` fixes language (ESCALATED agents propose at least 3, not already attempted)
- Must be read-only (except WebSearch/WebFetch tool usage)

## ACCEPTANCE CRITERIA

- [ ] All tests in `test_escalated_investigation_agent_1_prompt.py` PASS
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_escalated_investigation_agent_1_prompt.py -q 2>&1 | grep -q 'passed'
- [ ] Prompt file exists at expected path
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-1.md
- [ ] Prompt contains `{escalation_history}` placeholder
  Verify: grep -q '{escalation_history}' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-1.md
- [ ] Prompt contains WebSearch/WebFetch authorization
  Verify: grep -qE 'WebSearch|WebFetch' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-1.md
- [ ] Prompt contains ROOT_CAUSE RESULT field
  Verify: grep -q 'ROOT_CAUSE' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-1.md
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
