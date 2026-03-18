---
id: dso-awsv
status: open
deps: [dso-tk5c]
links: []
created: 2026-03-18T21:11:12Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-ffzi
---
# GREEN: Update SKILL.md Step 3 with TDD task structure, escape hatch, and behavioral-content definition

Edit plugins/dso/skills/implementation-plan/SKILL.md. Add 'TDD Task Structure' subsection to Step 3 Directives containing: (1) definition of 'behavioral content' (code with conditional logic, data transformation, decision points); (2) rule that every behavioral-content task must have a preceding RED test task as a declared dependency; (3) three unit exemption criteria with exact phrases 'no conditional logic', 'change-detector test', 'infrastructure-boundary-only'; (4) integration test task rule for external-boundary tasks (no RED-first dep required); (5) two integration exemption criteria with exact phrases 'existing coverage', 'no test environment'; (6) justification+plan-reviewer-validation requirement for all exemptions. Then: remove @pytest.mark.xfail from test_implementation_plan_skill_tdd_enforcement.py AND rewrite each test body as a positive assertion with explicit failure message (e.g., assert 'no conditional logic' in content, "Expected SKILL.md to contain 'no conditional logic'").

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py
- [ ] `ruff format --check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check scripts/*.py tests/**/*.py
- [ ] All tests in test_implementation_plan_skill_tdd_enforcement.py PASS with no @pytest.mark.xfail decorators
  Verify: python -m pytest $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_skill_tdd_enforcement.py -v 2>&1 | grep -q "passed" && ! grep -q "@pytest.mark.xfail" $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_skill_tdd_enforcement.py
- [ ] SKILL.md contains 'RED test task' dependency rule
  Verify: grep -q "RED test task" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/SKILL.md
- [ ] SKILL.md contains all three exact unit exemption phrases
  Verify: grep -q "no conditional logic" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/SKILL.md && grep -q "change-detector test" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/SKILL.md && grep -q "infrastructure-boundary-only" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/SKILL.md
- [ ] SKILL.md contains 'behavioral content' definition
  Verify: grep -q "behavioral content" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/SKILL.md
- [ ] SKILL.md contains TEST_CMD substitution instruction
  Verify: grep -q "TEST_CMD" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/SKILL.md

