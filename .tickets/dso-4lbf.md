---
id: dso-4lbf
status: closed
deps: []
links: []
created: 2026-03-21T17:59:42Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-l60c
---
# RED: Write failing tests for .test-index parsing and union merge in test-pre-commit-test-gate.sh

Add test functions to tests/hooks/test-pre-commit-test-gate.sh covering:
  1. test_gate_index_mapped_source_triggers — staged source file mapped in .test-index triggers gate (no test-gate-status = blocked)
  2. test_gate_index_union_with_fuzzy — source file with BOTH a fuzzy match AND an index entry; union of both test sets is required
  3. test_gate_missing_index_noop — .test-index does not exist = gate proceeds without error (fail-open)
  4. test_gate_index_empty_right_side_noop — source entry with no valid test paths on right side = treated as no association
  5. test_gate_index_multi_test_paths — source mapped to multiple test paths; all must have valid status

  TDD requirement: All five tests must FAIL (or return 'missing' RED-phase result) before Task D is implemented.
  Each test uses the isolated temp git repo pattern (make_test_repo / make_artifacts_dir helpers).
  .test-index file is written to the test repo root in each test.

  File to edit: tests/hooks/test-pre-commit-test-gate.sh
  Add each new test function before the run_test call block at the bottom of the file.
  Add run_test calls for all five new test functions in the run block.

## ACCEPTANCE CRITERIA

- [ ] Test file tests/hooks/test-pre-commit-test-gate.sh contains test_gate_index_mapped_source_triggers
  Verify: grep -q 'test_gate_index_mapped_source_triggers' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] Test file contains test_gate_index_union_with_fuzzy
  Verify: grep -q 'test_gate_index_union_with_fuzzy' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] Test file contains test_gate_missing_index_noop
  Verify: grep -q 'test_gate_missing_index_noop' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] Test file contains test_gate_index_empty_right_side_noop
  Verify: grep -q 'test_gate_index_empty_right_side_noop' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] Test file contains test_gate_index_multi_test_paths
  Verify: grep -q 'test_gate_index_multi_test_paths' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] All five new tests FAIL (exit non-zero pre-implementation) or return RED-phase 'missing' marker
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -E 'FAIL.*test_gate_index'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py 2>/dev/null || true
- [ ] ruff format check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py 2>/dev/null || true

## Notes

<!-- note-id: ggqfbfai -->
<!-- timestamp: 2026-03-21T18:04:52Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 4teym3cm -->
<!-- timestamp: 2026-03-21T18:05:02Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: iks9xgvn -->
<!-- timestamp: 2026-03-21T18:06:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: lcd9n5sa -->
<!-- timestamp: 2026-03-21T18:06:27Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete (RED task) ✓

<!-- note-id: s3gbiz4j -->
<!-- timestamp: 2026-03-21T18:26:52Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — 15 existing tests PASS, 3 new index tests FAIL (RED), 2 new noop tests PASS (correct behavior pre/post impl). test-doc-migration.sh failure is pre-existing.

<!-- note-id: 14smgyux -->
<!-- timestamp: 2026-03-21T18:27:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All 6 ACs verified. 5 test functions added, 3 FAIL (RED), 2 PASS (noop behavior correct pre-impl).
