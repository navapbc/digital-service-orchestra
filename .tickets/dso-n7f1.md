---
id: dso-n7f1
status: closed
deps: [dso-mck2]
links: []
created: 2026-03-22T03:54:45Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-fj1t
---
# Implement RED marker parsing in record-test-status.sh

Extend plugins/dso/hooks/record-test-status.sh to support the optional [marker_name] syntax in .test-index entries and tolerate test failures in the RED zone.

## Implementation Steps

1. Extend read_test_index_for_source: Parse the optional [marker_name] syntax after each test file path in .test-index entries. New format: 'source/path: test/path [first_red_test_name]'. Backward-compatible — entries without [marker] work as before. Return both the test path AND the marker (or empty string if absent).

2. Add get_red_zone_line_number function: Given a test file path and a marker function name, grep for the line number where 'def marker_name' (Python) or the equivalent bash pattern appears. Return the line number or -1 if not found. Emit WARNING to stderr if the marker is provided but not found.

3. Add parse_failing_tests_with_line_numbers function: Given a captured test output file and runner type (pytest/bash), parse the names and line numbers of failing tests.
   - For pytest: parse 'FAILED path/to/test.py::test_function_name' lines from verbose output
   - For bash: parse function names from assertion failure output

4. Modify the test execution loop: When a test file has a RED marker, after a non-zero exit:
   a. Get RED zone start line via get_red_zone_line_number
   b. If marker not found: warn and treat as blocking failure (existing behavior)
   c. Parse failing test names/line numbers from test output
   d. For each failing test: look up its line number in the test file
   e. If ALL failing tests are at or after the RED zone start line: tolerate (warn but non-blocking, write 'passed')
   f. If ANY failing test is before the RED zone start line: block (write 'failed')
   g. If exit_code != 0 but no failing test names could be parsed from output (empty result from parse_failing_tests_with_line_numbers): warn to stderr and block (write 'failed') — fail-safe: unknown parse results must never silently tolerate real failures

5. Update format comment at the top of record-test-status.sh to document the new .test-index [marker] syntax.

## TDD Requirement
Task dso-mck2's 5 tests must be RED before starting. After implementing, run:
  bash tests/hooks/test-record-test-status.sh
All 5 tests must turn GREEN.

## Files
- plugins/dso/hooks/record-test-status.sh — edit

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py
- [ ] All 5 tests from dso-mck2 now pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep -E 'test_red_marker_tolerates|test_red_marker_blocks|test_no_marker_backward|test_marker_not_found|test_red_zone_bash' | grep -c PASS | awk '{exit ($1 < 5)}'
- [ ] .test-index entries without a [marker] produce identical behavior to current (backward compat)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep 'test_no_marker_backward_compat' | grep -q PASS
- [ ] Marker not found in test file triggers stderr warning and blocking exit (non-zero)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep 'test_marker_not_found_falls_back_to_blocking' | grep -q PASS
- [ ] record-test-status.sh format comment updated to document [marker] syntax
  Verify: grep -q '\[first_red_test_name\]\|RED marker\|red.*marker' $(git rev-parse --show-toplevel)/plugins/dso/hooks/record-test-status.sh
- [ ] When exit_code != 0 but failing test names cannot be parsed from output, behavior is blocking (fail-safe: unknown parse result must not silently tolerate failures)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep 'test_marker_not_found_falls_back_to_blocking' | grep -q PASS


## Notes

**2026-03-22T04:21:44Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T04:22:33Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T04:22:37Z**

CHECKPOINT 3/6: Tests written (RED tests already exist from dso-mck2) ✓

**2026-03-22T04:28:55Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T04:28:55Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T04:38:30Z**

CHECKPOINT 6/6: Done ✓
