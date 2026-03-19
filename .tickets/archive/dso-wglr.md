---
id: dso-wglr
status: closed
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

## Notes

<!-- note-id: yosdin55 -->
<!-- timestamp: 2026-03-19T00:32:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: t1dvtuh4 -->
<!-- timestamp: 2026-03-19T00:32:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 6l6b21re -->
<!-- timestamp: 2026-03-19T00:33:02Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required — config-only change) ✓

<!-- note-id: 1r8w2oe5 -->
<!-- timestamp: 2026-03-19T00:33:09Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: oopfpmlq -->
<!-- timestamp: 2026-03-19T00:39:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — 166 pytest tests passed; bash tests/run-all.sh ran hook+script+eval suites successfully

<!-- note-id: 7qg03f7c -->
<!-- timestamp: 2026-03-19T00:39:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — commands.test_unit=bash tests/run-all.sh confirmed in workflow-config.conf; validate.sh line 110 reads this via _cfg('commands.test_unit')

<!-- note-id: bv2rc1h6 -->
<!-- timestamp: 2026-03-19T00:43:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: updated commands.test_unit to bash tests/run-all.sh — validate.sh now runs all test suites
