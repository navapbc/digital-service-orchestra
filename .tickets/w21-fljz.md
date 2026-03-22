---
id: w21-fljz
status: open
deps: [w21-ulsg]
links: []
created: 2026-03-21T23:37:29Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-5e4i
---
# RED: write config merge and fixture acceptance tests

Write failing tests in tests/scripts/test-project-detect.sh for config key merge and the full fixture acceptance test from the story's Done Definitions.

TDD Requirement: Write the following named tests FIRST (must FAIL before T7 is implemented):
- test_project_detect_suites_config_merge: fixture with dso-config.conf containing test.suite.custom.command='bash run-custom.sh' and test.suite.custom.speed_class='fast'; AND Makefile 'test-unit' target; config entry has runner=config, speed_class=fast; Makefile entry has speed_class=unknown
- test_project_detect_suites_config_overrides_autodiscovered: fixture where dso-config.conf has test.suite.unit.command='custom-unit-cmd' AND Makefile 'test-unit' target; result has ONE entry for name=unit with command='custom-unit-cmd' (config wins) and runner=config
- test_project_detect_suites_fixture_acceptance: full fixture per story Done Definition #4 — repo with Makefile 'test-unit' and 'test-e2e', a tests/models/ dir with test_model.py, and config test.suite.custom.command='bash run-custom.sh'; assert JSON output has exactly 4 entries (name: unit/make, e2e/make, models/pytest, custom/config); each entry has all required fields

Test file: tests/scripts/test-project-detect.sh
Source file: plugins/dso/scripts/project-detect.sh

Do NOT modify project-detect.sh in this task.

## Acceptance Criteria

- [ ] test_project_detect_suites_config_merge exists in test file
  Verify: grep -q 'test_project_detect_suites_config_merge' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] test_project_detect_suites_config_overrides_autodiscovered exists in test file
  Verify: grep -q 'test_project_detect_suites_config_overrides_autodiscovered' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] test_project_detect_suites_fixture_acceptance exists in test file
  Verify: grep -q 'test_project_detect_suites_fixture_acceptance' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] All three new tests FAIL (RED phase confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh 2>&1 | grep -qE 'FAIL.*suites_config_merge|FAIL.*suites_fixture_acceptance'
- [ ] ruff format --check passes (exit 0) on py files
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py
- [ ] ruff check passes (exit 0) on py files
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py

