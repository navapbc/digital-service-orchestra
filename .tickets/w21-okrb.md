---
id: w21-okrb
status: open
deps: [w21-f2k3]
links: []
created: 2026-03-21T23:36:59Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-5e4i
---
# RED: write --suites JSON schema, Makefile and pytest heuristic tests

Write failing tests in tests/scripts/test-project-detect.sh for the --suites output schema and Makefile/pytest discovery heuristics.

TDD Requirement: Write the following named tests FIRST (they must FAIL before T5 is implemented):
- test_project_detect_suites_json_schema: with --suites on a Makefile repo with test-unit target, output is valid JSON array; each element has keys: name (string), command (string), speed_class (one of fast|slow|unknown), runner (one of make|pytest|npm|bash|config)
- test_project_detect_suites_makefile: fixture with Makefile containing 'test-unit:' and 'test-e2e:' targets -> JSON array contains entries with runner=make, name=unit, name=e2e, command='make test-unit', command='make test-e2e'
- test_project_detect_suites_pytest: fixture with tests/models/ directory containing test_model.py -> JSON entry with runner=pytest, name=models, command='pytest tests/models/'
- test_project_detect_suites_makefile_name_derivation: Makefile target 'test-integration' -> name='integration'; target 'test_smoke' -> name='smoke' (strip test- or test_ prefix for name)

Test file: tests/scripts/test-project-detect.sh
Source file: plugins/dso/scripts/project-detect.sh

Do NOT modify project-detect.sh in this task.

## Acceptance Criteria

- [ ] test_project_detect_suites_json_schema exists in test file
  Verify: grep -q 'test_project_detect_suites_json_schema' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] test_project_detect_suites_makefile exists in test file
  Verify: grep -q 'test_project_detect_suites_makefile' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] test_project_detect_suites_pytest exists in test file
  Verify: grep -q 'test_project_detect_suites_pytest' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] test_project_detect_suites_makefile_name_derivation exists in test file
  Verify: grep -q 'test_project_detect_suites_makefile_name_derivation' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] All four new tests FAIL (RED phase confirmed pre-implementation)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh 2>&1 | grep -qE 'FAIL.*suites_json_schema|FAIL.*suites_makefile|FAIL.*suites_pytest'
- [ ] ruff format --check passes (exit 0) on py files
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py
- [ ] ruff check passes (exit 0) on py files
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py

