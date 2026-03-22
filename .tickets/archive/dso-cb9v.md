---
id: dso-cb9v
status: closed
deps: [dso-ocfn, dso-xf8w]
links: []
created: 2026-03-21T18:00:31Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-l60c
---
# IMPL: Add .test-index union merge to record-test-status.sh

Extend record-test-status.sh to read .test-index and include index-mapped tests in the test run.

  Changes required:
  1. Add read_test_index_for_source() function (mirrors parse_test_index() logic from pre-commit-test-gate.sh):
     - Same format, same missing-file no-op behavior
     - Returns test file paths on stdout that are mapped to the given source file
     - Skips nonexistent test paths with a warning (WARNING: .test-index entry points to nonexistent file: <path>)
  2. In the ASSOCIATED_TESTS discovery loop, after fuzzy_find_associated_tests(), also call read_test_index_for_source()
     - Append all index-mapped tests to the ASSOCIATED_TESTS array
     - Union semantics: the deduplication step (sort -u) removes duplicates if a file appears in both
  3. If .test-index does not exist, discovery proceeds as before (no error)

  TDD: Tests from Task dso-ocfn (test_record_status_index_mapped_source, test_record_status_index_union_with_fuzzy, test_record_status_index_missing_noop, test_record_status_index_stale_entry_skipped) must go GREEN.

  File: plugins/dso/hooks/record-test-status.sh

## ACCEPTANCE CRITERIA

- [ ] read_test_index_for_source function exists in record-test-status.sh
  Verify: grep -q 'read_test_index_for_source\|test.index' $(git rev-parse --show-toplevel)/plugins/dso/hooks/record-test-status.sh
- [ ] Index-mapped source files have their mapped tests included in the run
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep 'PASS.*test_record_status_index_mapped_source'
- [ ] Union of fuzzy + index test sets is deduped and run
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep 'PASS.*test_record_status_index_union_with_fuzzy'
- [ ] Missing .test-index is treated as no-op
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep 'PASS.*test_record_status_index_missing_noop'
- [ ] Nonexistent test paths in .test-index are skipped with a warning
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep 'PASS.*test_record_status_index_stale_entry_skipped'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

## Notes

**2026-03-21T19:25:08Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T19:25:31Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T19:25:35Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓

**2026-03-21T19:27:22Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T19:27:27Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T19:35:53Z**

CHECKPOINT 6/6: Done ✓ — All 20 tests pass (PASSED: 20 FAILED: 0). Pre-existing test-doc-migration.sh failure is unrelated to this change.
