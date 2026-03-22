---
id: w21-ulsg
status: closed
deps: [w21-okrb]
links: []
created: 2026-03-21T23:37:14Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-5e4i
---
# RED: write npm, bash runner, dedup, and precedence tests

Write failing tests in tests/scripts/test-project-detect.sh for npm scripts, bash runner heuristics, name derivation, dedup, and precedence ordering.

TDD Requirement: Write the following named tests FIRST (must FAIL before T6 implemented):
- test_project_detect_suites_npm: fixture with package.json scripts 'test:unit' and 'test:e2e' -> JSON entries with runner=npm, name=unit, name=e2e (strip 'test:' prefix for name), command='npm run test:unit', command='npm run test:e2e'
- test_project_detect_suites_bash_runner: fixture with executable test-hooks.sh in repo root -> JSON entry with runner=bash, name=hooks (strip 'test-' prefix and '.sh' suffix), command='bash test-hooks.sh'
- test_project_detect_suites_dedup_by_name: fixture with Makefile 'test-unit' target AND tests/unit/ pytest dir -> only ONE entry for name=unit emitted; Makefile (higher precedence) wins; runner=make
- test_project_detect_suites_precedence_config_over_makefile: fixture with Makefile 'test-unit' AND config key test.suite.unit.command='custom-cmd' -> config entry wins; runner=config, command='custom-cmd'
- test_project_detect_suites_bash_name_derivation: bash file 'run-tests-integration.sh' -> name='integration' (strip 'test-', 'run-tests-', leading 'test' variants, and '.sh' suffix)

Test file: tests/scripts/test-project-detect.sh
Source file: plugins/dso/scripts/project-detect.sh

Do NOT modify project-detect.sh in this task.

## Acceptance Criteria

- [ ] test_project_detect_suites_npm exists in test file
  Verify: grep -q 'test_project_detect_suites_npm' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] test_project_detect_suites_bash_runner exists in test file
  Verify: grep -q 'test_project_detect_suites_bash_runner' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] test_project_detect_suites_dedup_by_name exists in test file
  Verify: grep -q 'test_project_detect_suites_dedup_by_name' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] test_project_detect_suites_precedence_config_over_makefile exists in test file
  Verify: grep -q 'test_project_detect_suites_precedence_config_over_makefile' $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh
- [ ] All four new tests FAIL (RED phase confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh 2>&1 | grep -qE 'FAIL.*suites_npm|FAIL.*suites_bash|FAIL.*suites_dedup'
- [ ] ruff format --check passes (exit 0) on py files
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py
- [ ] ruff check passes (exit 0) on py files
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py


## Notes

**2026-03-22T00:22:30Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T00:22:53Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T00:23:42Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T00:23:57Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED-only task — no source changes needed)

**2026-03-22T00:23:58Z**

CHECKPOINT 5/6: Tests run — 5 new tests FAIL (RED confirmed), 101 existing assertions PASS ✓

**2026-03-22T00:24:16Z**

CHECKPOINT 6/6: Done ✓
