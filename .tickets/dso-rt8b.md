---
id: dso-rt8b
status: open
deps: [dso-n7f1]
links: []
created: 2026-03-22T03:54:56Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-fj1t
---
# Add integration test for end-to-end RED marker commit flow

Add an integration test to tests/hooks/test-record-test-status.sh that exercises the full end-to-end flow for the RED marker feature.

## Test: test_integration_red_marker_end_to_end

Steps:
1. Create a temp git repo with a source file and a test file containing both GREEN tests (before the RED marker) and RED tests (after the marker)
2. Add a .test-index entry mapping the source file to the test file with a [first_red_test_name] marker
3. Stage a change to the source file
4. Run record-test-status.sh
5. Assert: exit 0, test-gate-status says 'passed'
6. Run a second scenario with a GREEN test failure (a test before the RED marker fails)
7. Assert: exit 1, test-gate-status says 'failed'

## Integration Test Exemption Justification

This test may be written after Task dso-n7f1 (not RED-first), per the Integration Test Task Rule, criterion 1: the external boundary (test runner execution + file system) is already established and exercised by existing integration tests in test-record-test-status.sh. This test extends coverage to the new RED marker code path through the same boundary.

## Files
- tests/hooks/test-record-test-status.sh — edit (append integration test)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py
- [ ] Integration test function `test_integration_red_marker_end_to_end` exists in test file
  Verify: grep -q 'test_integration_red_marker_end_to_end' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] Integration test passes: GREEN tests before RED marker still block when they fail
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep 'test_integration_red_marker_end_to_end' | grep -q PASS

