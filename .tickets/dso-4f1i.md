---
id: dso-4f1i
status: in_progress
deps: []
links: []
created: 2026-03-18T21:11:22Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-ffzi
---
# RED: Write failing tests for tdd.md reviewer new dimensions

Create tests/skills/test_implementation_plan_tdd_reviewer.py with all tests in one file, all @pytest.mark.xfail(strict=True): (a) assert tdd.md contains 'red_test_dependency' — fails because not yet added; (b) assert tdd.md contains 'exemption_justification' — fails; (c) assert tdd.md describes exemption criteria (contains 'no conditional logic' or 'change-detector') — fails; (d) assert review-criteria.md does NOT contain 'ae8bfc7bd9a0d7e3' — fails because old hash IS present. Test (d) must include precondition: read file, assert it exists and is non-empty, then assert hash absent. Add comment: '# NOTE: This test passes vacuously if review-criteria.md is deleted. Acceptable risk — file deletion would fail other tests.' All tests XFAIL; suite green.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py
- [ ] `ruff format --check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check scripts/*.py tests/**/*.py
- [ ] tests/skills/test_implementation_plan_tdd_reviewer.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_tdd_reviewer.py
- [ ] File contains >=4 @pytest.mark.xfail-marked tests
  Verify: grep -c '@pytest.mark.xfail' $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_tdd_reviewer.py | awk '{exit ($1 < 4)}'
- [ ] Running tests shows XFAIL results
  Verify: python -m pytest $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_tdd_reviewer.py -v 2>&1 | grep -q 'XFAIL'
- [ ] File contains vacuous-pass acknowledgment comment for hash-absence test
  Verify: grep -q "vacuous" $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_tdd_reviewer.py

