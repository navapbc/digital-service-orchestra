---
id: w21-dedx
status: closed
deps: []
links: []
created: 2026-03-20T19:09:07Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-uqfn
---
# RED: Write failing tests for record-test-status.sh

Write the test file tests/hooks/test-record-test-status.sh BEFORE the implementation exists (TDD RED phase).

The test file should cover all record-test-status.sh behaviors:
1. test_discovers_associated_tests: given a source file foo.py with an associated test_foo.py, the script discovers and runs test_foo.py
2. test_records_passed_status: when associated tests pass, writes 'passed' and diff_hash to test-gate-status file
3. test_records_failed_status: when associated tests fail, writes 'failed' (or similar) to test-gate-status file
4. test_exit_144_actionable_message: when test runner exits 144 (SIGURG timeout), error message includes test-batched.sh command with --timeout flag and resume instructions
5. test_no_associated_tests_exempts: source file with no associated test writes an exempt marker or exits 0 cleanly
6. test_hash_matches_compute_diff_hash: diff_hash recorded in test-gate-status must match output of compute-diff-hash.sh at same git state
7. test_captures_hash_after_staging: hash is captured AFTER git add (same point as record-review.sh) so it matches at verify time

Test infrastructure:
- Use isolated temp git repos for all tests that involve git operations
- Set WORKFLOW_PLUGIN_ARTIFACTS_DIR to per-test temp dir
- Source plugins/dso/hooks/lib/deps.sh
- Mock or stub test runner for exit 144 test case

TDD requirement: All tests MUST FAIL before record-test-status.sh exists. Confirm RED state.

## Acceptance Criteria

- [ ] tests/hooks/test-record-test-status.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] Test file contains at least 6 test functions
  Verify: grep -c 'test_' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh | awk '{exit ($1 < 6)}'
- [ ] Tests use isolated temp git repos
  Verify: grep -q 'mktemp -d' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] Tests verify exit 144 actionable message references test-batched.sh
  Verify: grep -q 'test-batched' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] Tests verify diff_hash captured after staging
  Verify: grep -q 'test_hash_matches\|test_captures_hash\|after_staging\|after.*add' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh


## Notes

**2026-03-20T19:30:08Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T19:30:43Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T19:32:16Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T19:32:20Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T19:34:43Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T19:35:13Z**

CHECKPOINT 6/6: Done ✓
