---
id: dso-9mvn
status: in_progress
deps: [dso-oo92]
links: []
created: 2026-03-22T15:44:09Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ond9
---
# RED: Write failing tests for YAML validation, sanitization, and edge cases in ci-generator.sh


## Description

Add failing tests to tests/scripts/test-ci-generator.sh covering YAML validation, command sanitization, and remaining edge cases.

TDD REQUIREMENT: Tests must be added to the existing test file and must fail (RED) before dso-cwyt implements the features. These tests extend the existing test file from dso-oo92.

Tests to add:
1. test_command_sanitization_strips_metacharacters: suite command with shell metacharacters (e.g., 'make test; rm -rf /') produces sanitized output in YAML (no semicolons or dangerous chars)
2. test_yaml_validation_blocks_invalid_yaml: if generated YAML is invalid, exit code is 2 and no file is written
3. test_special_chars_in_suite_name_produce_valid_job_id: suite name 'my_test suite' produces job ID 'test-my-test-suite'
4. test_all_unknown_suites_noninteractive_go_to_slow: all-unknown suite list in --non-interactive mode writes only ci-slow.yml
5. test_temp_then_move_pattern: generator writes to temp path first, only moves to final path after validation succeeds

These tests go into the existing file tests/scripts/test-ci-generator.sh (append to it).

test-exempt: N/A — this task writes tests, not production code.

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] test-ci-generator.sh contains test_command_sanitization_strips_metacharacters
  Verify: grep -q 'test_command_sanitization_strips_metacharacters' $(git rev-parse --show-toplevel)/tests/scripts/test-ci-generator.sh
- [ ] test-ci-generator.sh contains test_yaml_validation_blocks_invalid_yaml
  Verify: grep -q 'test_yaml_validation_blocks_invalid_yaml' $(git rev-parse --show-toplevel)/tests/scripts/test-ci-generator.sh
- [ ] dso-oo92 is complete before this task begins (test-ci-generator.sh exists)
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-ci-generator.sh
- [ ] New tests fail (RED) before dso-cwyt implementation
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ci-generator.sh 2>&1 | grep -q 'FAIL.*test_command_sanitization'

## Notes

<!-- note-id: q1o3n2ex -->
<!-- timestamp: 2026-03-22T16:45:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: hd573djn -->
<!-- timestamp: 2026-03-22T16:46:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: npu8m8oe -->
<!-- timestamp: 2026-03-22T16:57:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: rasuqrt2 -->
<!-- timestamp: 2026-03-22T16:57:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: yo03g60s -->
<!-- timestamp: 2026-03-22T16:58:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: pya910dc -->
<!-- timestamp: 2026-03-22T17:00:21Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — 2 RED tests added (test_command_sanitization_strips_metacharacters, test_yaml_validation_blocks_invalid_yaml), 3 GREEN tests added (already implemented). Existing 9 tests still pass. AC verified.
