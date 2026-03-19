---
id: dso-ezme
status: in_progress
deps: []
links: []
created: 2026-03-19T18:36:55Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# RED: Write failing tests for escalated-investigation-agent-4.md (Empirical/Logging Agent) prompt content requirements

## Description

Write failing tests (RED) that assert `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-4.md` exists and contains the required content for the Empirical/Logging Agent role.

**File to create**: `tests/skills/test_escalated_investigation_agent_4_prompt.py`

**Implementation steps**:
1. Create `tests/skills/test_escalated_investigation_agent_4_prompt.py`
2. Agent 4 is the most novel — it has unique capabilities not present in ADVANCED: authorized to add logging, can veto other agents, must revert artifacts
3. Define `PROMPT_FILE` pointing to `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-4.md`
4. Write the test functions below — all must FAIL before dso-56g6 is implemented

**Test functions** (all RED before dso-56g6):
- `test_escalated_agent_4_prompt_file_exists` — asserts the file exists
- `test_escalated_agent_4_prompt_empirical_agent_role` — asserts content contains `Empirical` or `empirical` (role framing)
- `test_escalated_agent_4_prompt_logging_authorization` — asserts content contains `logging` or `add logging` (authorized action)
- `test_escalated_agent_4_prompt_debugging_authorization` — asserts content contains `debugging` or `enable debugging` (authorized action)
- `test_escalated_agent_4_prompt_veto_authority` — asserts content contains `veto` (Agent 4's unique power)
- `test_escalated_agent_4_prompt_artifact_revert` — asserts content contains `revert` or `stash` (cleanup requirement — logging/debugging additions must not persist)
- `test_escalated_agent_4_prompt_escalation_history_placeholder` — asserts content contains `{escalation_history}`
- `test_escalated_agent_4_prompt_context_placeholders` — asserts content contains `{failing_tests}`, `{stack_trace}`, `{commit_history}`
- `test_escalated_agent_4_prompt_result_schema` — asserts content contains `ROOT_CAUSE` and `confidence`
- `test_escalated_agent_4_prompt_at_least_3_fixes` — asserts content contains `at least 3` or `three` fixes
- `test_escalated_agent_4_prompt_validates_or_vetoes` — asserts content contains `validate` or `validates` (empirically validates or vetoes hypotheses from agents 1-3)

**TDD Requirement**: All tests must FAIL before dso-56g6 creates the prompt file.

## ACCEPTANCE CRITERIA

- [ ] Test file `tests/skills/test_escalated_investigation_agent_4_prompt.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_escalated_investigation_agent_4_prompt.py
- [ ] File contains at least 11 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_escalated_investigation_agent_4_prompt.py | awk '{exit ($1 < 11)}'
- [ ] All tests FAIL before dso-56g6 is implemented
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_escalated_investigation_agent_4_prompt.py -q 2>&1 | grep -q 'FAILED\|failed\|error'
- [ ] `ruff check tests/skills/test_escalated_investigation_agent_4_prompt.py` passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_escalated_investigation_agent_4_prompt.py
- [ ] `ruff format --check tests/skills/test_escalated_investigation_agent_4_prompt.py` passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_escalated_investigation_agent_4_prompt.py

## Notes

**2026-03-19T18:44:26Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T18:44:36Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T18:45:14Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T18:45:20Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T18:45:26Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-19T18:45:34Z**

CHECKPOINT 6/6: Done ✓

**2026-03-19T18:46:55Z**

CHECKPOINT 6/6: Done ✓ — 11 RED tests
