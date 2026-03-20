---
id: w21-4dnw
status: closed
deps: [w21-eq69]
links: []
created: 2026-03-20T22:02:08Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-8jaf
---
# RED: Write failing tests for exemption support in pre-commit-test-gate.sh

Write failing tests for exemption support in hooks/pre-commit-test-gate.sh BEFORE the gate is modified (TDD RED phase).

Add the following test cases to tests/hooks/test-pre-commit-test-gate.sh:

TEST 9: test_gate_passes_when_test_exempted
- Create a source file with an associated test
- Write a valid test-gate-status file with 'passed' and matching hash
- Write an exemption entry for the associated test's node_id (or test file path) to $ARTIFACTS_DIR/test-exemptions
- Verify the gate exits 0 (exemption respected)
- The exemption means: if ALL associated tests for a staged file are in the exemptions list, the gate treats that file as having passed tests

TEST 10: test_gate_blocked_when_test_not_exempted
- Create a source file with an associated test
- Write an exemption entry for a DIFFERENT test (not the one associated with the staged file)
- Do NOT write test-gate-status
- Verify the gate exits non-zero (missing status, wrong exemption does not help)

TEST 11: test_gate_passes_no_status_but_fully_exempted
- Create a source file whose associated test is fully exempted
- Do NOT write test-gate-status
- Write an exemption entry covering the associated test
- Verify the gate exits 0 (exempted tests pass gate even without recorded status)

Note: The exemption lookup must use the test FILE path (not node_id) as the key in the exemptions file, because the gate discovers test files via convention. Alternatively, both scripts can use the test file path as the node_id. Verify this contract in the tests.

RED-phase guard: wrap each new test in the same style as existing tests in the file (check if GATE_HOOK exists).

TDD Requirement: The new test functions must fail (or report 'hook not found (RED)') before the gate is modified. Running bash tests/hooks/test-pre-commit-test-gate.sh should still exit 0 overall (RED-phase guards pass trivially).

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/hooks/test-pre-commit-test-gate.sh contains test_gate_passes_when_test_exempted
  Verify: grep -q 'test_gate_passes_when_test_exempted' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] tests/hooks/test-pre-commit-test-gate.sh contains test_gate_blocked_when_test_not_exempted
  Verify: grep -q 'test_gate_blocked_when_test_not_exempted' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] tests/hooks/test-pre-commit-test-gate.sh contains test_gate_passes_no_status_but_fully_exempted
  Verify: grep -q 'test_gate_passes_no_status_but_fully_exempted' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] Full test suite still exits 0 (RED-phase guards allow passing without gate modification)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh

## Notes

**2026-03-20T22:47:13Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T22:47:29Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T22:48:46Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T22:48:49Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED test task — no gate implementation needed)

**2026-03-20T22:50:26Z**

CHECKPOINT 5/6: Tests pass — 11/11 PASSED, exit 0. RED-phase guards detect missing exemption support in gate hook ✓

**2026-03-20T23:02:36Z**

CHECKPOINT 6/6: Done ✓
