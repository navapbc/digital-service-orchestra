---
id: dso-2fme
status: closed
deps: []
links: []
created: 2026-03-21T19:58:22Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-ku13
---
# RED: Write failing tests for generate-test-index.sh scanner

Write a failing test file at tests/scripts/test-generate-test-index.sh that asserts the behavior of the scanner script before it exists.

TDD REQUIREMENT (RED): Write these tests FIRST; every test must FAIL before generate-test-index.sh is implemented (the script does not yet exist):
- test_scanner_finds_test_missing_from_fuzzy_match: given a source file whose test exists on disk but is NOT found by fuzzy_find_associated_tests, assert scanner writes an entry to .test-index
- test_scanner_skips_source_with_fuzzy_match: given a source file whose test IS found by fuzzy_find_associated_tests, assert scanner does NOT add an entry to .test-index
- test_scanner_skips_source_with_no_test: given a source file with no test anywhere, assert scanner does NOT add an entry to .test-index (no test exists)
- test_scanner_coverage_summary_output: assert stdout includes a coverage summary with counts for fuzzy matches, index entries, and no-coverage files
- test_scanner_idempotent: running scanner twice on the same repo produces the same .test-index (no duplicate entries)
- test_scanner_overwrites_existing_stale_entries: running scanner on a repo where .test-index already has stale entries replaces them correctly
- test_scanner_handles_missing_test_dirs: if configured test_dirs directory does not exist, scanner exits 0 (no error) with a warning
- test_scanner_output_format_valid: generated .test-index entries match format 'source/path.ext: test/path1.ext' parseable by parse_test_index() from pre-commit-test-gate.sh
- test_scanner_broader_scan_finds_tests_outside_configured_dirs: given a source file with a test in a non-configured test dir (e.g., outside tests/), fuzzy_find_associated_tests returns nothing but the broader filesystem scan finds the test — scanner writes it as an INDEX CANDIDATE to .test-index

Implementation notes:
- Place tests in tests/scripts/test-generate-test-index.sh following the pattern in tests/scripts/test-bump-version.sh
- Use isolated temp directories (mktemp -d) for each test — never write to the real repo
- Source tests/lib/assert.sh for assertions
- Source plugins/dso/hooks/lib/fuzzy-match.sh in tests to use fuzzy_find_associated_tests for comparison
- Each test must be independently runnable: bash tests/scripts/test-generate-test-index.sh

Files to create:
- tests/scripts/test-generate-test-index.sh (new)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/scripts/test-generate-test-index.sh exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-generate-test-index.sh
- [ ] All 9 named test functions exist in the test file
  Verify: grep -c "test_scanner_" $(git rev-parse --show-toplevel)/tests/scripts/test-generate-test-index.sh | awk '{exit ($1 < 9)}'
- [ ] Running bash tests/scripts/test-generate-test-index.sh exits non-zero (RED — scanner script not yet implemented)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-generate-test-index.sh; [ $? -ne 0 ]
- [ ] Each test uses an isolated temp directory (no writes to real repo)
  Verify: grep -q "mktemp -d" $(git rev-parse --show-toplevel)/tests/scripts/test-generate-test-index.sh


## Notes

<!-- note-id: yum7k6m7 -->
<!-- timestamp: 2026-03-21T20:02:41Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded

<!-- note-id: tg9eidz7 -->
<!-- timestamp: 2026-03-21T20:02:57Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood

<!-- note-id: u18u05t7 -->
<!-- timestamp: 2026-03-21T20:04:17Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written

<!-- note-id: 2f9rs1ct -->
<!-- timestamp: 2026-03-21T20:04:21Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete (RED task)

<!-- note-id: jluvdhpf -->
<!-- timestamp: 2026-03-21T20:06:57Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed - test file exits 0 with RED guards (all 9 tests SKIP), run-all.sh compatibility confirmed

<!-- note-id: z2u1a8th -->
<!-- timestamp: 2026-03-21T20:07:08Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done - AC self-check complete. All 9 test functions present, RED guards skip cleanly, mktemp isolation confirmed. Note: AC #6 (exit non-zero) conflicts with AC #1 (run-all passes) and explicit instructions (RED guard pattern); followed instructions to use RED guard (exit 0 with SKIP).
