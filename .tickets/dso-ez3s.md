---
id: dso-ez3s
status: in_progress
deps: [dso-2fme]
links: []
created: 2026-03-21T19:58:46Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-ku13
---
# IMPL: Implement generate-test-index.sh scanner script

Implement plugins/dso/scripts/generate-test-index.sh — a scanner that finds source files whose tests are missed by fuzzy matching, generates a .test-index file, and reports coverage.

TDD REQUIREMENT (GREEN): All tests in tests/scripts/test-generate-test-index.sh must pass after this task (they were written RED in the preceding task).

Algorithm:
1. Accept optional --test-dirs=<dirs> flag (colon-separated, default: reads test_gate.test_dirs from .claude/dso-config.conf, falls back to tests/)
2. Accept optional --src-dirs=<dirs> flag (colon-separated dirs to scan for source files, default: plugins/ scripts/ app/ src/ — skip any dir that does not exist)
3. For each file found recursively in src-dirs:
   a. Skip files identified as test files by fuzzy_is_test_file() from hooks/lib/fuzzy-match.sh
   b. Run fuzzy_find_associated_tests() — collect any matches (fuzzy hits)
   c. Independently scan test-dirs for ANY file whose normalized basename contains BOTH the normalized source basename AND the string 'test' (this is a broader search than fuzzy match — fuzzy only requires source-name substring)
   d. If fuzzy_find_associated_tests found NO matches AND broader scan found at least one test: record as an INDEX CANDIDATE (fuzzy miss, test exists)
   e. If fuzzy_find_associated_tests found matches: record as FUZZY MATCH (no .test-index entry needed)
   f. If neither fuzzy nor broader scan found a test: record as NO COVERAGE
4. Write .test-index at repo root — only INDEX CANDIDATE entries (format: 'source/path: test/path1, test/path2')
   - If .test-index already exists, replace it entirely (overwrite, not append)
   - Write atomically: use tmp file + mv
5. Print coverage summary to stdout:
   Files with fuzzy matches: N
   Files with .test-index entries: N
   Files with no test coverage: N
6. Exit 0 on success

Implementation:
- Script: plugins/dso/scripts/generate-test-index.sh
- Source plugins/dso/hooks/lib/fuzzy-match.sh for fuzzy_normalize, fuzzy_is_test_file, fuzzy_find_associated_tests
- Use REPO_ROOT from git rev-parse --show-toplevel
- Follow bash conventions from other scripts in plugins/dso/scripts/ (set -uo pipefail, usage block, etc.)
- The broader scan in step 3c must distinguish 'fuzzy miss' from 'no test at all'. Use normalized substring: if normalized(test_basename) contains normalized(src_basename) AND normalized(test_basename) contains 'test', it is a candidate. This is identical to fuzzy_find_associated_tests logic. The key difference is: step 3c searches ALL test-dirs directories (not just the configured subset), while fuzzy match uses only configured test_dirs.
  NOTE: Actually use the SAME test_dirs for both. The distinction is: fuzzy_find_associated_tests checks that normalized source name is SUBSTRING of normalized test name. Step 3c does the same check but as a more thorough scan — ensuring we catch all files in configured dirs. If fuzzy returns nothing but step 3c returns something, those are index candidates.
  CLARIFICATION: fuzzy_find_associated_tests ONLY searches the configured test_dirs. The 'broader scan' in step 3c MUST search ALL test dirs in the repo (find "$REPO_ROOT" -type f), not just configured test_dirs. This ensures that if a test exists in a non-standard directory (not in test_dirs config), it is still caught as an INDEX CANDIDATE. The key invariant: FUZZY MATCH = fuzzy_find_associated_tests found something in configured dirs; INDEX CANDIDATE = fuzzy found nothing in configured dirs, but a broader filesystem scan found a test file anywhere in the repo; NO COVERAGE = no test found anywhere.

Files to create/edit:
- plugins/dso/scripts/generate-test-index.sh (new)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] plugins/dso/scripts/generate-test-index.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/generate-test-index.sh
- [ ] All 8 tests in tests/scripts/test-generate-test-index.sh pass (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-generate-test-index.sh
- [ ] Scanner correctly identifies INDEX CANDIDATE: source file with existing test missed by fuzzy match gets a .test-index entry
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-generate-test-index.sh (covered by test_scanner_finds_test_missing_from_fuzzy_match)
- [ ] Scanner correctly skips FUZZY MATCH: source file whose test is found by fuzzy match does NOT get a .test-index entry
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-generate-test-index.sh (covered by test_scanner_skips_source_with_fuzzy_match)
- [ ] Coverage summary output contains 'Files with fuzzy matches', 'Files with .test-index entries', 'Files with no test coverage'
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/generate-test-index.sh 2>&1 | grep -q "Files with fuzzy matches"
- [ ] Output .test-index format is parseable by parse_test_index() in pre-commit-test-gate.sh (format: 'source/path: test/path')
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-generate-test-index.sh (covered by test_scanner_output_format_valid)


## Notes

**2026-03-21T20:11:27Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T20:11:49Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T20:12:35Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓

**2026-03-21T20:13:41Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T20:13:42Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T20:13:53Z**

CHECKPOINT 6/6: Done ✓
