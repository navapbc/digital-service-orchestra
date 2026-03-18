---
id: dso-gp00
status: open
deps: [dso-gsqg]
links: []
created: 2026-03-18T21:11:46Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-ffzi
---
# GREEN: Add RED test task and test-exempt categories to ACCEPTANCE-CRITERIA-LIBRARY.md

Edit plugins/dso/docs/ACCEPTANCE-CRITERIA-LIBRARY.md. Add 'Category: RED Test Task' with criteria: test file exists at expected path (Verify: test -f {test_path}), test function exists by name (Verify: grep -q 'def {test_name}' {test_path}), running the test returns non-zero exit pre-implementation (Verify: python -m pytest {test_path}::{test_name} 2>&1; test $? -ne 0). Add 'Category: Test-Exempt Task' with criteria: task description contains test-exempt justification citing one of the defined criteria (Verify: grep -q 'test-exempt:' {ticket_path}). Then: remove @pytest.mark.xfail from test_implementation_plan_ac_library.py AND rewrite each test body as a positive assertion with explicit failure message.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py
- [ ] `ruff format --check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check scripts/*.py tests/**/*.py
- [ ] All tests in test_implementation_plan_ac_library.py PASS with no @pytest.mark.xfail decorators
  Verify: python -m pytest $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_ac_library.py -v 2>&1 | grep -q "passed" && ! grep -q "@pytest.mark.xfail" $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_ac_library.py
- [ ] 'Category: RED Test Task' section present in ACCEPTANCE-CRITERIA-LIBRARY.md
  Verify: grep -q "Category: RED Test Task" $(git rev-parse --show-toplevel)/plugins/dso/docs/ACCEPTANCE-CRITERIA-LIBRARY.md
- [ ] 'Category: Test-Exempt Task' section present in ACCEPTANCE-CRITERIA-LIBRARY.md
  Verify: grep -q "Category: Test-Exempt Task" $(git rev-parse --show-toplevel)/plugins/dso/docs/ACCEPTANCE-CRITERIA-LIBRARY.md

