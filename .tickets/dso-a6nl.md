---
id: dso-a6nl
status: closed
deps: [dso-wqt4]
links: []
created: 2026-03-21T16:16:08Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-tpzd
---
# RED: Extend test-record-test-status.sh with fuzzy match discovery tests

Add new test cases to tests/hooks/test-record-test-status.sh that verify the recorder discovers non-Python test files via fuzzy matching. These tests must FAIL against the current Python-only discovery logic. After Task 6, they pass GREEN.

## TDD Requirement

New tests must FAIL against current record-test-status.sh which uses the hardcoded 'test_${name_no_ext}' pattern. A bash script staged would find no associated test with the current logic. After Task 6 (uses fuzzy_find_associated_tests), the tests pass.

## Files

- EDIT: tests/hooks/test-record-test-status.sh (add new test functions)

## New Test Functions to Add

1. test_record_bash_script_discovers_test:
   - Create isolated git repo
   - Create scripts/bump-version.sh + tests/test-bump-version.sh
   - Stage bump-version.sh
   - Set RECORD_TEST_STATUS_RUNNER to a mock that exits 0 (so tests 'pass')
   - Run record-test-status.sh
   - Read written test-gate-status file
   - Assert tested_files line contains 'test-bump-version.sh'
   - RED: Current recorder uses test_bumpversionsh pattern, finds nothing, exits 0 without writing status

2. test_record_uses_configured_test_dirs:
   - Create isolated git repo
   - Create scripts/bump-version.sh + unit_tests/test-bump-version.sh (NOT in tests/)
   - Stage bump-version.sh
   - Set TEST_GATE_TEST_DIRS_OVERRIDE=unit_tests/ 
   - Set RECORD_TEST_STATUS_RUNNER to mock passing runner
   - Run record-test-status.sh
   - Assert test-gate-status written with tested_files containing test-bump-version.sh from unit_tests/
   - RED: Current recorder ignores TEST_GATE_TEST_DIRS_OVERRIDE, searches everywhere with find . (may coincidentally find it, but tested_files will show wrong path or not find it when search is scoped)

Add these test functions and their run_test invocations at the bottom, before print_summary.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] test_record_bash_script_discovers_test function added
  Verify: grep -q 'test_record_bash_script_discovers_test' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] test_record_uses_configured_test_dirs function added
  Verify: grep -q 'test_record_uses_configured_test_dirs' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh
- [ ] New tests FAIL (RED) against current recorder
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep -q 'FAIL:.*test_record_bash_script_discovers_test'


## Notes

**2026-03-21T17:14:35Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T17:14:51Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T17:15:37Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T17:15:42Z**

CHECKPOINT 4/6: Implementation complete (RED task — no impl needed) ✓

**2026-03-21T17:17:55Z**

CHECKPOINT 5/6: Validation passed ✓ — 10 existing tests PASS, 2 new tests FAIL (RED as expected). ruff check/format pass.

**2026-03-21T17:18:00Z**

CHECKPOINT 6/6: Done ✓
