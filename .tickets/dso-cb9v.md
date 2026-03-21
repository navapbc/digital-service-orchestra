---
id: dso-cb9v
status: open
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
