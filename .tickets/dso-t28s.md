---
id: dso-t28s
status: open
deps: []
links: []
created: 2026-03-19T18:36:47Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# RED: Write failing tests for escalated-investigation-agent-3.md (Code Tracer) prompt content requirements

## Description

Write failing tests (RED) that assert `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-3.md` exists and contains the required content for the Code Tracer role.

**File to create**: `tests/skills/test_escalated_investigation_agent_3_prompt.py`

**Implementation steps**:
1. Create `tests/skills/test_escalated_investigation_agent_3_prompt.py`
2. Follow the same structure as `tests/skills/test_advanced_investigation_agent_a_prompt.py` (Code Tracer is similar to ADVANCED Agent A but extended for ESCALATED tier)
3. Define `PROMPT_FILE` pointing to `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-3.md`
4. Write the test functions below — all must FAIL before dso-cxuh is implemented

**Test functions** (all RED before dso-cxuh):
- `test_escalated_agent_3_prompt_file_exists` — asserts the file exists
- `test_escalated_agent_3_prompt_code_tracer_role` — asserts content contains `Code Tracer` or `code tracer`
- `test_escalated_agent_3_prompt_execution_path_tracing` — asserts content contains `execution path`
- `test_escalated_agent_3_prompt_dependency_ordered_reading` — asserts content contains `dependency-ordered` or `dependency ordered` (ESCALATED adds this to code tracer)
- `test_escalated_agent_3_prompt_intermediate_variable_tracking` — asserts content contains `intermediate variable` or `variable tracking`
- `test_escalated_agent_3_prompt_five_whys` — asserts content contains `five whys`
- `test_escalated_agent_3_prompt_escalation_history_placeholder` — asserts content contains `{escalation_history}`
- `test_escalated_agent_3_prompt_context_placeholders` — asserts content contains `{failing_tests}`, `{stack_trace}`, `{commit_history}`
- `test_escalated_agent_3_prompt_result_schema` — asserts content contains `ROOT_CAUSE` and `confidence`
- `test_escalated_agent_3_prompt_at_least_3_fixes` — asserts content contains `at least 3` or `three` fixes
- `test_escalated_agent_3_prompt_read_only_constraint` — asserts content contains `read-only` or `do not modify`

**TDD Requirement**: All tests must FAIL before dso-cxuh creates the prompt file.

## ACCEPTANCE CRITERIA

- [ ] Test file `tests/skills/test_escalated_investigation_agent_3_prompt.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_escalated_investigation_agent_3_prompt.py
- [ ] File contains at least 11 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_escalated_investigation_agent_3_prompt.py | awk '{exit ($1 < 11)}'
- [ ] All tests FAIL before dso-cxuh is implemented
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_escalated_investigation_agent_3_prompt.py -q 2>&1 | grep -q 'FAILED\|failed\|error'
- [ ] `ruff check tests/skills/test_escalated_investigation_agent_3_prompt.py` passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_escalated_investigation_agent_3_prompt.py
- [ ] `ruff format --check tests/skills/test_escalated_investigation_agent_3_prompt.py` passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_escalated_investigation_agent_3_prompt.py
