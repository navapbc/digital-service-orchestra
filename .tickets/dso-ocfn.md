---
id: dso-ocfn
status: open
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
