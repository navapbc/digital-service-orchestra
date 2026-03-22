---
id: dso-ydzw
status: closed
deps: []
links: []
created: 2026-03-21T16:14:55Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-tpzd
---
# RED: Write failing tests for fuzzy_find_associated_tests() in hooks/lib/fuzzy-match.sh

Create tests/hooks/test-fuzzy-match.sh with failing tests for the fuzzy_find_associated_tests() function. The function does not yet exist — all tests must fail (RED) when run before Task 2 is implemented.

## TDD Requirement

Write the following failing test functions BEFORE fuzzy-match.sh exists. Each function must FAIL when the library is absent. The test file must source the library and gracefully handle its absence (print FAIL, not crash).

Test functions to implement:
- test_bash_convention_matches: create tmp repo with scripts/bump-version.sh + tests/test-bump-version.sh; call fuzzy_find_associated_tests; assert non-empty result
- test_python_convention_matches: create tmp repo with src/foo.py + tests/test_foo.py; assert match found
- test_typescript_convention_matches: create tmp repo with src/parser.ts + tests/test_parser.ts (prefix-style, normalized testparserts contains parserts); assert match found
- test_negative_no_false_positive: create tmp repo with src/version.py + tests/test-bump-version.sh; assert result is EMPTY (versionpy is NOT a substring of testbumpversionsh)
- test_empty_source_guard: call fuzzy_find_associated_tests with empty string source; assert returns 0 exit with empty output (no crash)
- test_is_test_file_skip_bash: call fuzzy_is_test_file test-bump-version.sh; assert returns 0 (true = is a test file)
- test_is_test_file_skip_py: call fuzzy_is_test_file test_foo.py; assert returns 0 (true)
- test_custom_test_dirs: create tmp repo with scripts/bump-version.sh + unit_tests/test-bump-version.sh; call with test_dirs=unit_tests/; assert match found
- test_benchmark_20_files: create 20 source+test file pairs in tmp repo; time fuzzy_find_associated_tests for each; assert total < 10 seconds
- test_dogfood_bump_version: simulate real repo structure with plugins/dso/scripts/bump-version.sh + tests/hooks/test-bump-version.sh; assert fuzzy match finds it

## Files

- CREATE: tests/hooks/test-fuzzy-match.sh

## Algorithmic Note

Full basename normalization: strip all non-alphanumeric chars from filename including extension. bump-version.sh -> bumpversionsh; test-bump-version.sh -> testbumpversionsh. bumpversionsh IS a substring of testbumpversionsh. Go _test.go and TypeScript .test.ts suffix conventions do NOT match under this algorithm (known limitation); use prefix-style test names (test_foo.ts, test-foo.go) for those stacks.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] tests/hooks/test-fuzzy-match.sh exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh
- [ ] Contains test_bash_convention_matches function
  Verify: grep -q 'test_bash_convention_matches' $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh
- [ ] Contains test_python_convention_matches function
  Verify: grep -q 'test_python_convention_matches' $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh
- [ ] Contains test_negative_no_false_positive function
  Verify: grep -q 'test_negative_no_false_positive' $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh
- [ ] Contains test_empty_source_guard function
  Verify: grep -q 'test_empty_source_guard' $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh
- [ ] Contains test_is_test_file_skip_bash function
  Verify: grep -q 'test_is_test_file_skip_bash' $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh
- [ ] Contains test_custom_test_dirs function
  Verify: grep -q 'test_custom_test_dirs' $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh
- [ ] Contains test_benchmark_20_files function
  Verify: grep -q 'test_benchmark_20_files' $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh
- [ ] Contains test_dogfood_bump_version function
  Verify: grep -q 'test_dogfood_bump_version' $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh
- [ ] Running test-fuzzy-match.sh before fuzzy-match.sh is created returns FAIL output (RED state)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh 2>&1 | grep -q FAIL


## Notes

**2026-03-21T16:23:19Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T16:23:35Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T16:24:27Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T16:24:31Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T16:47:27Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T16:47:42Z**

CHECKPOINT 6/6: Done ✓
