---
id: dso-haj7
status: closed
deps: []
links: []
created: 2026-03-21T07:10:01Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ay8w
---
# RED: Write failing stress test skeleton for ticket concurrency harness

Write the initial failing stress test skeleton at tests/scripts/test-ticket-concurrency-stress.sh.

TDD Requirement: Create a test file with test function stubs and assertion placeholders that FAIL before the full harness is implemented. Running the stub test file directly should return non-zero (RED).

Implementation Steps:
1. Create tests/scripts/test-ticket-concurrency-stress.sh following pattern of test-ticket-e2e.sh: shebang, header comment, set -uo pipefail, source assert.sh and git-fixtures.sh, _CLEANUP_DIRS pattern + trap for cleanup.
2. Define stub function test_concurrent_stress_5_sessions_10_ops(): _snapshot_fail at top, comment STUB: harness not yet implemented, and a single assert_eq that always fails: assert_eq stress test: harness implemented yes no.
3. Call stub function and print_summary.
4. Make file executable: chmod +x tests/scripts/test-ticket-concurrency-stress.sh
5. DO NOT add to tests/scripts/run-all.sh yet — the stub always fails and would break the test suite. Registration in run-all.sh is done in dso-ltwr (IMPL task) after the full harness is implemented and passes.

File path: tests/scripts/test-ticket-concurrency-stress.sh

## Gap Analysis Amendment (Gap #1 — Cross-Task Interference)

The stub test always fails by design (RED). If it were added to run-all.sh in this task, `bash tests/run-all.sh` would fail, contradicting the project invariant that all committed code leaves the suite green. The stub file must exist on disk without being registered in the test runner until dso-ltwr makes it pass. This task is independently committable and green because the stub file is excluded from run-all.sh.

## Acceptance Criteria

- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `bash tests/run-all.sh` passes (exit 0) — stub file not yet in run-all.sh
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] tests/scripts/test-ticket-concurrency-stress.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh
- [ ] Test file contains stub function test_concurrent_stress_5_sessions_10_ops
  Verify: grep -q 'test_concurrent_stress_5_sessions_10_ops' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh
- [ ] stub test NOT referenced in tests/scripts/run-all.sh (deferred to dso-ltwr)
  Verify: ! grep -q 'test-ticket-concurrency-stress' $(git rev-parse --show-toplevel)/tests/scripts/run-all.sh
- [ ] Running the stub test alone returns non-zero exit (RED — harness not yet implemented)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-concurrency-stress.sh; test $? -ne 0


## Notes

**2026-03-21T07:16:19Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T07:20:50Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T07:34:02Z**

CHECKPOINT 6/6: Done ✓ — RED stress test skeleton.
