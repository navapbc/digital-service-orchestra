---
id: w22-vea4
status: in_progress
deps: []
links: []
created: 2026-03-22T13:19:56Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-zp4d
---
# Write RED tests asserting new review dimension names are valid and old names rejected

## Description

**This is the RED test task.** Write failing tests that assert the NEW 5-dimension schema (correctness, verification, hygiene, design, maintainability) is accepted by the review validators. These tests must fail (RED) before Task w22-4391 renames the validators.

### Dimension rename mapping

| Old name | New name |
|----------|----------|
| code_hygiene | hygiene |
| object_oriented_design | design |
| readability | maintainability |
| functionality | correctness |
| testing_coverage | verification |

### TDD Requirement

This IS the RED test task. Write the failing tests first — the tests will fail until Task w22-4391 implements the rename.

### 1. Append to tests/hooks/test-validate-review-output.sh

Add two test cases at the END of the test file (after all existing tests):

**test_new_dimension_names_accepted**: Construct valid reviewer-findings JSON using new dimension names (correctness, verification, hygiene, design, maintainability) and pass it to `validate-review-output.sh code-review-dispatch <file>`. Assert exit 0.

**test_old_dimension_names_rejected**: Construct reviewer-findings JSON using old dimension names (functionality, testing_coverage, code_hygiene, object_oriented_design, readability) and pass it to `validate-review-output.sh code-review-dispatch <file>`. Assert exit 1.

### 2. Append to tests/scripts/test-write-reviewer-findings.sh

Add two test cases at the END of the test file (after all existing tests):

**test_write_new_dimension_names_accepted**: Pipe reviewer-findings JSON with new dimension names to `write-reviewer-findings.sh`. Assert exit 0 and a SHA-256 hash is printed to stdout.

**test_write_old_dimension_names_rejected**: Pipe reviewer-findings JSON with old dimension names to `write-reviewer-findings.sh`. Assert exit 1 (rejected by validator).

### 3. Add RED markers to .test-index

The .test-index file maps source files to test files. Find entries containing the test files being modified and append RED markers for the first new failing test function in each.

For `tests/hooks/test-validate-review-output.sh`: the test gate entry covering this file is on the line for `plugins/dso/commands/review.md`. Append a RED marker to that line so the test gate tolerates failures at and after `test_new_dimension_names_accepted`.

For `tests/scripts/test-write-reviewer-findings.sh`: similarly, append a RED marker for `test_write_new_dimension_names_accepted`.

RED marker format appended to the test file path in .test-index:
```
tests/hooks/test-validate-review-output.sh [test_new_dimension_names_accepted]
tests/scripts/test-write-reviewer-findings.sh [test_write_new_dimension_names_accepted]
```

### Stability check

After this task is committed, ALL pre-existing tests in these files must still PASS. Only the two new tests (`test_new_dimension_names_accepted`, `test_write_new_dimension_names_accepted`) are expected to FAIL (RED).

## File Impact

| File | Action |
|------|--------|
| tests/hooks/test-validate-review-output.sh | Edit — append 2 test cases |
| tests/scripts/test-write-reviewer-findings.sh | Edit — append 2 test cases |
| .test-index | Edit — add RED markers for new failing tests |

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0) for all pre-existing tests (new tests exempted via RED markers)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-validate-review-output.sh 2>&1 | grep -v "test_new_dimension_names_accepted\|test_old_dimension_names_rejected" | grep -c "FAIL" | awk '{exit ($1 > 0)}'
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] test_new_dimension_names_accepted exists in tests/hooks/test-validate-review-output.sh
  Verify: grep -q 'test_new_dimension_names_accepted' $(git rev-parse --show-toplevel)/tests/hooks/test-validate-review-output.sh
- [ ] test_old_dimension_names_rejected exists in tests/hooks/test-validate-review-output.sh
  Verify: grep -q 'test_old_dimension_names_rejected' $(git rev-parse --show-toplevel)/tests/hooks/test-validate-review-output.sh
- [ ] test_write_new_dimension_names_accepted exists in tests/scripts/test-write-reviewer-findings.sh
  Verify: grep -q 'test_write_new_dimension_names_accepted' $(git rev-parse --show-toplevel)/tests/scripts/test-write-reviewer-findings.sh
- [ ] test_write_old_dimension_names_rejected exists in tests/scripts/test-write-reviewer-findings.sh
  Verify: grep -q 'test_write_old_dimension_names_rejected' $(git rev-parse --show-toplevel)/tests/scripts/test-write-reviewer-findings.sh
- [ ] New tests fail (RED) before Task w22-4391 — test_new_dimension_names_accepted and test_write_new_dimension_names_accepted must output FAIL when run against unmodified codebase
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-validate-review-output.sh 2>&1 | grep 'test_new_dimension_names_accepted' | grep -q 'FAIL'
- [ ] .test-index RED markers added for test_new_dimension_names_accepted and test_write_new_dimension_names_accepted
  Verify: grep -q 'test_new_dimension_names_accepted' $(git rev-parse --show-toplevel)/.test-index

## Notes

**2026-03-22T13:23:31Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T13:24:01Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T13:24:44Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T13:24:49Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T13:24:56Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T13:26:13Z**

CHECKPOINT 6/6: Done ✓
