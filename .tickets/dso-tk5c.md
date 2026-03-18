---
id: dso-tk5c
status: open
deps: []
links: []
created: 2026-03-18T21:11:00Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-ffzi
---
# RED: Write failing tests for SKILL.md TDD enforcement language

Create tests/skills/test_implementation_plan_skill_tdd_enforcement.py with Python tests asserting SKILL.md contains: 'no conditional logic', 'change-detector test', 'infrastructure-boundary-only', 'RED test task', 'behavioral content', integration test task rule language, 'existing coverage', 'no test environment', justification requirement. All tests marked @pytest.mark.xfail(strict=True, reason='RED: SKILL.md not yet updated'). Use literal string matching (no regex). Tests fail (XFAIL) against unmodified SKILL.md; suite remains green.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py
- [ ] `ruff format --check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check scripts/*.py tests/**/*.py
- [ ] tests/skills/test_implementation_plan_skill_tdd_enforcement.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_skill_tdd_enforcement.py
- [ ] File contains >=8 @pytest.mark.xfail-marked tests covering all required phrase assertions
  Verify: grep -c '@pytest.mark.xfail' $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_skill_tdd_enforcement.py | awk '{exit ($1 < 8)}'
- [ ] Running tests shows XFAIL results confirming RED state
  Verify: python -m pytest $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_skill_tdd_enforcement.py -v 2>&1 | grep -q 'XFAIL'
- [ ] Tests use literal string match for 'infrastructure-boundary-only'
  Verify: grep -q 'infrastructure-boundary-only' $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_skill_tdd_enforcement.py

