---
id: w21-0xmw
status: in_progress
deps: [w21-s63d]
links: []
created: 2026-03-19T15:20:49Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-nl5m
---
# RED: Write failing tests for fix-task-tdd.md and fix-task-mechanical.md retirement

Write failing Python tests in tests/skills/test_fix_task_prompts_retired.py that assert:
1. fix-task-tdd.md contains a deprecation notice or forward pointer to dso:fix-bug
2. fix-task-mechanical.md contains a deprecation notice or forward pointer to dso:fix-bug
3. Neither file claims to be the primary path for bug resolution without redirecting to dso:fix-bug

TDD REQUIREMENT: All tests must FAIL (RED) before the prompt updates in the next task. Run: python -m pytest tests/skills/test_fix_task_prompts_retired.py -v to confirm RED.

Implementation notes:
- REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
- FIX_TASK_TDD = REPO_ROOT / 'plugins' / 'dso' / 'skills' / 'debug-everything' / 'prompts' / 'fix-task-tdd.md'
- FIX_TASK_MECHANICAL = REPO_ROOT / 'plugins' / 'dso' / 'skills' / 'debug-everything' / 'prompts' / 'fix-task-mechanical.md'
- Check for strings like 'deprecated', 'forward pointer', 'dso:fix-bug', or 'use dso:fix-bug instead'

## ACCEPTANCE CRITERIA

- [ ] `python -m pytest tests/skills/test_fix_task_prompts_retired.py -v` fails (RED) before prompt changes
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_fix_task_prompts_retired.py -v 2>&1 | grep -q "FAILED"
- [ ] Test file tests/skills/test_fix_task_prompts_retired.py exists
  Verify: cd $(git rev-parse --show-toplevel) && test -f tests/skills/test_fix_task_prompts_retired.py
- [ ] Test file contains at least 2 test functions (one per prompt file)
  Verify: cd $(git rev-parse --show-toplevel) && grep -c "def test_" tests/skills/test_fix_task_prompts_retired.py | awk '{exit ($1 < 2)}'
- [ ] Existing tests in tests/skills/ still pass
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/ -v --tb=short -k "not fix_task_prompts_retired"

## Notes

**2026-03-19T17:10:32Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T17:10:57Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T17:11:33Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T17:12:12Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED test-only task; test file written at tests/skills/test_fix_task_prompts_retired.py)

**2026-03-19T17:12:26Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-19T17:12:56Z**

CHECKPOINT 6/6: Done ✓ — AC1 pass (4 RED tests confirmed), AC2 pass (file exists), AC3 pass (4 test functions), AC4 pass (118 existing tests unchanged; 30 pre-existing RED tests in test_advanced_investigation_agent_{a,b}_prompt.py owned by w21-hb1j)

**2026-03-19T17:22:20Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/skills/test_fix_task_prompts_retired.py. 4 RED tests.
