---
id: dso-wglr
status: open
deps: []
links: []
created: 2026-03-18T22:59:19Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-p2d3
---
# As a developer, validate.sh runs all project tests through the configured test command


## What
Update `commands.test_unit` in `workflow-config.conf` from `python3 -m pytest tests/plugin/ tests/scripts/ tests/skills/ -q` to `bash tests/run-all.sh`. This ensures validate.sh's `tests` check runs all project tests (hooks, scripts, and evals), not just Python tests.

## Why
The project's authoritative test runner is `tests/run-all.sh`, which runs hook tests, script tests, and evals. The current `commands.test_unit` only covers Python-pytest-based tests. Shell tests in `tests/hooks/` and `tests/scripts/` are not caught by `validate.sh --ci` with the current configuration.

The epic states: "This project's configuration file should be configured to run this project's tests."

## Scope

IN:
- `workflow-config.conf`: Update `commands.test_unit=bash tests/run-all.sh`

OUT: validate.sh structure changes (dso-guxa), retiring check-plugin-test-needed.sh (dso-l24u), documentation (SD story)

Note: `commands.test=bash tests/run-all.sh` already exists and is correct. Only `commands.test_unit` needs updating.

## Done Definitions

- When this story is complete, `commands.test_unit` in `workflow-config.conf` is `bash tests/run-all.sh`
  ← Satisfies: "This project's configuration file should be configured to run this project's tests"
- When this story is complete, `validate.sh --ci` tests check runs all project tests including shell tests in `tests/hooks/` and `tests/scripts/`
  ← Satisfies: "This project's configuration file should be configured to run this project's tests"
- When this story is complete, `validate.sh --ci` passes with the new test command
  ← Satisfies: "This project's configuration file should be configured to run this project's tests"

## Considerations
- [Testing] `bash tests/run-all.sh` runs 3 suites (hooks + scripts concurrent, evals sequential) with SUITE_TIMEOUT=180s each; TIMEOUT_TESTS in validate.sh is 600s — adequate margin

## File Impact
- `workflow-config.conf` - Update `commands.test_unit` from `python3 -m pytest tests/plugin/ tests/scripts/ tests/skills/ -q` to `bash tests/run-all.sh`
- `tests/run-all.sh` - Verify it correctly runs all test suites (hooks, scripts, evals) as the authoritative test runner
- `validate.sh` - Verify it correctly invokes the updated `commands.test_unit` configuration and that timeout values are adequate (TIMEOUT_TESTS=600s vs SUITE_TIMEOUT=180s per suite)
