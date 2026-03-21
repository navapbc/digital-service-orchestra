---
id: dso-ocfn
status: in_progress
deps: []
links: []
created: 2026-03-21T17:59:59Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-l60c
---
# RED: Write failing tests for .test-index support in test-record-test-status.sh

Add test functions to tests/hooks/test-record-test-status.sh covering:
  1. test_record_status_index_mapped_source — source file mapped in .test-index; record-test-status.sh includes the mapped test file in the test run (even if fuzzy match would not find it)
  2. test_record_status_index_union_with_fuzzy — source file with both fuzzy match AND index entry; union of both test sets is included in the run
  3. test_record_status_index_missing_noop — .test-index does not exist; record-test-status.sh proceeds normally (no error)
  4. test_record_status_index_stale_entry_skipped — .test-index entry pointing to a nonexistent test file; record-test-status.sh skips it with a warning (does not attempt to run nonexistent file)

  TDD requirement: All four tests must FAIL before Task F is implemented.
  Use the existing isolated test repo helpers in test-record-test-status.sh.
  Write .test-index file to the test repo root in each applicable test.

  File to edit: tests/hooks/test-record-test-status.sh
  Add functions and run_test / test runner calls at the end of the test suite.

## ACCEPTANCE CRITERIA

- [ ] Test file tests/hooks/test-record-test-status.sh contains test_record_status_index_mapped_source
  Verify: grep -q 'test_record_status_index_mapped_source' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] Test file contains test_record_status_index_union_with_fuzzy
  Verify: grep -q 'test_record_status_index_union_with_fuzzy' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] Test file contains test_record_status_index_missing_noop
  Verify: grep -q 'test_record_status_index_missing_noop' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] Test file contains test_record_status_index_stale_entry_skipped
  Verify: grep -q 'test_record_status_index_stale_entry_skipped' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] All four tests FAIL pre-implementation
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep -E 'FAIL.*test_record_status_index'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py 2>/dev/null || true

## Notes

<!-- note-id: wuybak4a -->
<!-- timestamp: 2026-03-21T18:42:25Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: zh6d98af -->
<!-- timestamp: 2026-03-21T18:42:37Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: hmhyslds -->
<!-- timestamp: 2026-03-21T18:43:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: he8qrdfq -->
<!-- timestamp: 2026-03-21T18:43:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete (RED task) ✓

<!-- note-id: n3zulux8 -->
<!-- timestamp: 2026-03-21T18:51:15Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — 4 new tests FAIL (RED), 16 existing tests PASS. run-all.sh expected to fail because RED tests are included in the suite (same pattern as prior RED tests in this file).

<!-- note-id: 9alb5hu5 -->
<!-- timestamp: 2026-03-21T18:51:19Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
