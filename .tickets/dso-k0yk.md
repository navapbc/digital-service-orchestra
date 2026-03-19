---
id: dso-k0yk
status: closed
deps: []
links: []
created: 2026-03-19T05:01:18Z
type: task
priority: 0
assignee: Joe Oakhart
parent: w21-auwy
---
# RED: Write failing Python content tests for fix-bug skill

Write a failing pytest file at tests/skills/test_fix_bug_skill.py that verifies the content requirements of the fix-bug skill file.

TDD Requirement: Write this file in RED phase -- all tests must FAIL because plugins/dso/skills/fix-bug/SKILL.md does not yet exist. Run 'python3 -m pytest tests/skills/test_fix_bug_skill.py -q' to confirm failure before marking done.

Test Functions to Create:
1. test_fix_bug_skill_file_exists -- asserts SKILL_FILE.exists() is True
2. test_fix_bug_skill_frontmatter_name -- asserts 'name: fix-bug' in content
3. test_fix_bug_skill_user_invocable -- asserts 'user-invocable: true' in content
4. test_fix_bug_skill_mechanical_classification -- asserts 'mechanical' and 'import error' and 'lint violation' in content
5. test_fix_bug_skill_scoring_rubric_severity -- asserts severity scoring language in content
6. test_fix_bug_skill_scoring_rubric_complexity -- asserts complexity scoring language in content
7. test_fix_bug_skill_scoring_rubric_environment -- asserts environment scoring language in content
8. test_fix_bug_skill_routing_thresholds -- asserts 'BASIC', 'INTERMEDIATE', 'ADVANCED' and threshold values in content
9. test_fix_bug_skill_result_schema -- asserts 'ROOT_CAUSE' and 'confidence' in content (RESULT report schema)
10. test_fix_bug_skill_discovery_file_protocol -- asserts 'discovery file' in content
11. test_fix_bug_skill_hypothesis_testing_phase -- asserts 'hypothesis' in content
12. test_fix_bug_skill_tdd_workflow_config_pattern -- asserts 'read-config.sh' in content (config resolution pattern)

File Structure: Follow tests/skills/test_implementation_plan_skill_tdd_enforcement.py pattern.
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / 'plugins' / 'dso' / 'skills' / 'fix-bug' / 'SKILL.md'

## ACCEPTANCE CRITERIA

- [ ] Test file exists at expected path
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] Test file contains at least 10 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py | awk '{exit ($1 < 10)}'
- [ ] Running tests against missing skill file returns non-zero exit (RED state confirmed)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py -q; test $? -ne 0
- [ ] test_fix_bug_skill_file_exists function is present
  Verify: grep -q 'def test_fix_bug_skill_file_exists' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] test_fix_bug_skill_mechanical_classification function is present
  Verify: grep -q 'def test_fix_bug_skill_mechanical_classification' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] test_fix_bug_skill_routing_thresholds function is present
  Verify: grep -q 'def test_fix_bug_skill_routing_thresholds' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] test_fix_bug_skill_result_schema function is present
  Verify: grep -q 'def test_fix_bug_skill_result_schema' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] test_fix_bug_skill_hypothesis_testing_phase function is present
  Verify: grep -q 'def test_fix_bug_skill_hypothesis_testing_phase' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] ruff format check passes on test file
  Verify: ruff format --check $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py


## Notes

**2026-03-19T05:07:48Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T05:07:57Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T05:08:25Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T05:08:33Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED task — test file written, no implementation needed)

**2026-03-19T05:09:35Z**

CHECKPOINT 5/6: Validation passed ✓ — run-all.sh: 53 passed, 0 failed; new test file: 12 failed (RED state confirmed as expected)

**2026-03-19T05:09:39Z**

CHECKPOINT 6/6: Done ✓ — All 9 AC criteria verified: file exists, 12 test functions, RED state (non-zero exit), all required function names present, ruff format passes
