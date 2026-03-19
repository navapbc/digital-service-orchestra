---
id: w21-hb1j
status: closed
deps: []
links: []
created: 2026-03-19T15:21:36Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dksj
---
# RED: Write failing tests for advanced-investigation-agent-b.md prompt (historical lens)

Create tests/skills/test_advanced_investigation_agent_b_prompt.py with failing tests for the Agent B (historical) prompt template.

Tests must assert advanced-investigation-agent-b.md:
1. File exists at plugins/dso/skills/fix-bug/prompts/advanced-investigation-agent-b.md
2. Contains timeline reconstruction language ('timeline reconstruction' or 'timeline')
3. Contains fault tree analysis ('fault tree')
4. Contains git bisect technique ('git bisect')
5. Contains hypothesis generation from change history ('hypothesis')
6. Contains self-reflection step before reporting ('self-reflection')
7. Contains ROOT_CAUSE RESULT schema field
8. Contains confidence RESULT schema field
9. Contains context placeholders: {failing_tests}, {stack_trace}, {commit_history}
10. Contains RESULT output section marker
11. Contains at least 2 proposed fixes language ('at least 2' or 'alternative_fixes')
12. Contains convergence_score RESULT field (ADVANCED adds this to schema)
13. Contains fishbone_categories RESULT field

Pattern: Follow test_basic_investigation_prompt.py / test_intermediate_investigation_prompt.py / test_advanced_investigation_agent_a_prompt.py structure exactly.

TDD Requirement (RED): advanced-investigation-agent-b.md does NOT exist yet, so all existence and content tests will FAIL immediately.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff lint passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format-check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file tests/skills/test_advanced_investigation_agent_b_prompt.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_advanced_investigation_agent_b_prompt.py
- [ ] All tests in test file FAIL (RED) before prompt file creation
  Verify: python -m pytest tests/skills/test_advanced_investigation_agent_b_prompt.py -v 2>&1 | grep -q 'FAILED'
- [ ] Test file contains at least 8 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_advanced_investigation_agent_b_prompt.py | awk '{exit ($1 < 8)}'


## Notes

**2026-03-19T17:10:42Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T17:11:00Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T17:11:31Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T17:11:44Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED task — no prompt file to implement; tests intentionally fail)

**2026-03-19T17:21:34Z**

CHECKPOINT 5/6: Validation passed ✓ (ruff lint + format both pass; 15 tests all RED as required)

**2026-03-19T17:21:41Z**

CHECKPOINT 6/6: Done ✓ — AC1 PASS (file exists), AC2 PASS (all 15 tests RED), AC3 PASS (15 test functions >= 8), ruff lint PASS, ruff format PASS. Note: tests/run-all.sh has pre-existing failures (fix-cascade-recovery-skill-reads-config eval, test-check-test-isolation-baseline.sh) unrelated to this task.

**2026-03-19T17:22:20Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/skills/test_advanced_investigation_agent_b_prompt.py. 15 RED tests.
