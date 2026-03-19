---
id: dso-gnbz
status: closed
deps: []
links: []
created: 2026-03-19T18:36:46Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# RED: Write failing tests for escalated-investigation-agent-2.md (History Analyst) prompt content requirements

## Description

Write failing tests (RED) that assert `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-2.md` exists and contains the required content for the History Analyst role.

**File to create**: `tests/skills/test_escalated_investigation_agent_2_prompt.py`

**Implementation steps**:
1. Create `tests/skills/test_escalated_investigation_agent_2_prompt.py`
2. Follow the same structure as `tests/skills/test_advanced_investigation_agent_b_prompt.py` (History Analyst is similar to ADVANCED Agent B but with extended scope)
3. Define `PROMPT_FILE` pointing to `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-2.md`
4. Write the test functions below — all must FAIL before dso-sjck is implemented

**Test functions** (all RED before dso-sjck):
- `test_escalated_agent_2_prompt_file_exists` — asserts the file exists
- `test_escalated_agent_2_prompt_history_analyst_role` — asserts content contains `History Analyst` or `history analyst`
- `test_escalated_agent_2_prompt_timeline_reconstruction` — asserts content contains `timeline reconstruction`
- `test_escalated_agent_2_prompt_fault_tree_analysis` — asserts content contains `fault tree`
- `test_escalated_agent_2_prompt_commit_bisection` — asserts content contains `bisect` or `bisection`
- `test_escalated_agent_2_prompt_escalation_history_placeholder` — asserts content contains `{escalation_history}`
- `test_escalated_agent_2_prompt_context_placeholders` — asserts content contains `{failing_tests}`, `{stack_trace}`, `{commit_history}`
- `test_escalated_agent_2_prompt_result_schema` — asserts content contains `ROOT_CAUSE` and `confidence`
- `test_escalated_agent_2_prompt_at_least_3_fixes` — asserts content contains `at least 3` or `three` fixes (ESCALATED requirement)
- `test_escalated_agent_2_prompt_read_only_constraint` — asserts content contains `read-only` or `do not modify`

**TDD Requirement**: All tests must FAIL before dso-sjck creates the prompt file.

## ACCEPTANCE CRITERIA

- [ ] Test file `tests/skills/test_escalated_investigation_agent_2_prompt.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_escalated_investigation_agent_2_prompt.py
- [ ] File contains at least 10 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_escalated_investigation_agent_2_prompt.py | awk '{exit ($1 < 10)}'
- [ ] All tests FAIL before dso-sjck is implemented
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_escalated_investigation_agent_2_prompt.py -q 2>&1 | grep -q 'FAILED\|failed\|error'
- [ ] `ruff check tests/skills/test_escalated_investigation_agent_2_prompt.py` passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_escalated_investigation_agent_2_prompt.py
- [ ] `ruff format --check tests/skills/test_escalated_investigation_agent_2_prompt.py` passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_escalated_investigation_agent_2_prompt.py

## Notes

**2026-03-19T18:44:33Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T18:44:38Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T18:45:08Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T18:45:11Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T18:45:19Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-19T18:45:39Z**

CHECKPOINT 6/6: Done ✓

**2026-03-19T18:46:55Z**

CHECKPOINT 6/6: Done ✓ — 10 RED tests
