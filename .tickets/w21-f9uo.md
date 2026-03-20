---
id: w21-f9uo
status: open
deps: [w21-wzgp, w21-l7zk]
links: []
created: 2026-03-20T19:09:51Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-uqfn
---
# RED: Write failing tests for test gate coexistence and .pre-commit-config.yaml registration

Write the test file tests/hooks/test-test-gate-coexistence.sh BEFORE the registration changes exist (TDD RED phase).

The test file covers coexistence between the test gate and review gate, and verifies .pre-commit-config.yaml registration:

1. test_test_gate_only_failure_leaves_review_status_unchanged:
   When pre-commit-test-gate.sh blocks (MISSING test-gate-status) but review-status is valid,
   the commit is blocked with a test-gate-specific error and the review-status file content is NOT modified.

2. test_review_gate_only_failure_leaves_test_status_unchanged:
   When pre-commit-review-gate.sh blocks (no review-status) but test-gate-status is valid,
   the commit is blocked with a review-gate-specific error and the test-gate-status file content is NOT modified.

3. test_both_gates_pass_commit_succeeds:
   When both test-gate-status (passed, hash match) and review-status (passed, hash match) are present,
   a pre-commit run of both hooks succeeds (both exit 0).

4. test_pre_commit_config_registers_test_gate:
   .pre-commit-config.yaml contains an entry with id: pre-commit-test-gate that invokes pre-commit-test-gate.sh.

5. test_test_gate_error_message_is_test_specific:
   The error message from pre-commit-test-gate.sh does NOT reference /dso:review or review-gate concepts;
   it references test-gate-specific instructions.

Test infrastructure:
- Use isolated temp git repos
- Set WORKFLOW_PLUGIN_ARTIFACTS_DIR to per-test temp dirs
- Tests 1-3 run the hook scripts directly (not via pre-commit) against temp repos
- Test 4 is a static file check against the real .pre-commit-config.yaml

TDD requirement: Tests 1-3 and test 5 will FAIL before the hooks exist. Test 4 will FAIL before .pre-commit-config.yaml is updated. Confirm RED state.

## Acceptance Criteria

- [ ] tests/hooks/test-test-gate-coexistence.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/hooks/test-test-gate-coexistence.sh
- [ ] Test file contains at least 5 test functions
  Verify: grep -c 'test_' $(git rev-parse --show-toplevel)/tests/hooks/test-test-gate-coexistence.sh | awk '{exit ($1 < 5)}'
- [ ] Tests include verification that review-status is not modified by test gate failure
  Verify: grep -q 'review.status\|review_status' $(git rev-parse --show-toplevel)/tests/hooks/test-test-gate-coexistence.sh
- [ ] Tests include verification that .pre-commit-config.yaml registers test gate
  Verify: grep -q 'pre-commit-config\|pre_commit_config' $(git rev-parse --show-toplevel)/tests/hooks/test-test-gate-coexistence.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

