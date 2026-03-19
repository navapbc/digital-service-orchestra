---
id: dso-6xe1
status: in_progress
deps: []
links: []
created: 2026-03-19T18:36:37Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# RED: Write failing tests for escalated-investigation-agent-1.md (Web Researcher) prompt content requirements

## Description

Write failing tests (RED) that assert `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-1.md` exists and contains the required content for the Web Researcher role.

**File to create**: `tests/skills/test_escalated_investigation_agent_1_prompt.py`

**Implementation steps**:
1. Create `tests/skills/test_escalated_investigation_agent_1_prompt.py`
2. Follow the same structure as `tests/skills/test_advanced_investigation_agent_a_prompt.py`
3. Define `PROMPT_FILE` pointing to `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-1.md`
4. Write the test functions listed below — all must FAIL before dso-mn94 is implemented

**Test functions** (all RED before dso-mn94):
- `test_escalated_agent_1_prompt_file_exists` — asserts the file exists
- `test_escalated_agent_1_prompt_web_researcher_role` — asserts content contains `Web Researcher` or `web researcher` (role framing)
- `test_escalated_agent_1_prompt_websearch_authorization` — asserts content contains `WebSearch` or `WebFetch` (authorized tools)
- `test_escalated_agent_1_prompt_error_pattern_analysis` — asserts content contains `error pattern` (primary investigation technique)
- `test_escalated_agent_1_prompt_similar_issue_correlation` — asserts content contains `similar issue` (correlation technique)
- `test_escalated_agent_1_prompt_dependency_changelogs` — asserts content contains `changelog` or `dependency changelog` (changelog analysis)
- `test_escalated_agent_1_prompt_context_placeholders` — asserts content contains `{failing_tests}`, `{stack_trace}`, `{commit_history}`, and `{escalation_history}`
- `test_escalated_agent_1_prompt_result_schema` — asserts content contains `ROOT_CAUSE` and `confidence`
- `test_escalated_agent_1_prompt_at_least_3_fixes` — asserts content contains `at least 3` or `three` fixes language (ESCALATED agents propose at least 3 fixes not already attempted)
- `test_escalated_agent_1_prompt_read_only_constraint` — asserts content contains `read-only` or `do not modify` constraint (all agents except Agent 4 are read-only)

**TDD Requirement**: All tests must FAIL before dso-mn94 creates the prompt file. Do NOT create the prompt file in this task.

## ACCEPTANCE CRITERIA

- [ ] Test file `tests/skills/test_escalated_investigation_agent_1_prompt.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_escalated_investigation_agent_1_prompt.py
- [ ] File contains at least 10 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_escalated_investigation_agent_1_prompt.py | awk '{exit ($1 < 10)}'
- [ ] All tests FAIL before dso-mn94 is implemented
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_escalated_investigation_agent_1_prompt.py -q 2>&1 | grep -q 'FAILED\|failed\|error'
- [ ] `ruff check tests/skills/test_escalated_investigation_agent_1_prompt.py` passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_escalated_investigation_agent_1_prompt.py
- [ ] `ruff format --check tests/skills/test_escalated_investigation_agent_1_prompt.py` passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_escalated_investigation_agent_1_prompt.py

## Notes

<!-- note-id: 398ytq8v -->
<!-- timestamp: 2026-03-19T18:44:27Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: xaym46k6 -->
<!-- timestamp: 2026-03-19T18:44:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 8io7g456 -->
<!-- timestamp: 2026-03-19T18:45:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: dsl5gtja -->
<!-- timestamp: 2026-03-19T18:45:08Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: qczsmwtr -->
<!-- timestamp: 2026-03-19T18:45:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: rdhimdpt -->
<!-- timestamp: 2026-03-19T18:45:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

**2026-03-19T18:46:55Z**

CHECKPOINT 6/6: Done ✓ — 10 RED tests
