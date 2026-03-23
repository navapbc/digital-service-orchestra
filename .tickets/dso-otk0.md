---
id: dso-otk0
status: open
deps: []
links: []
created: 2026-03-23T00:22:33Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2a9w
---
# RED: Write failing tests for cutover script phase-gate skeleton

TDD RED phase: write the failing test file for the cutover script's phase-gate skeleton.

File to create: tests/scripts/test-cutover-tickets-migration.sh

Tests to write (all must FAIL before T2 implementation):
1. test_cutover_phases_execute_in_order — run script, assert all 5 phase names appear in order in the log, assert exit 0
2. test_cutover_creates_log_file_with_timestamp — assert log file exists at CUTOVER_LOG_DIR matching cutover-YYYY-MM-DDTHH-MM-SS.log, assert non-empty
3. test_cutover_dry_run_flag_produces_output_without_creating_state_file — run with --dry-run, assert [DRY RUN] prefix in output, assert no state file, assert exit 0

Each test: set up minimal temp git repo fixture, invoke script, assert observable outputs, clean up.
Pattern: follow tests/scripts/test-merge-to-main.sh (source tests/lib/assert.sh, TMPDIR fixture, trap cleanup).
Fuzzy-match: 'cutoverticketsmigrationssh' IS a substring of 'testcutoverticketsmigrationssh'. No .test-index entry needed.

## Acceptance Criteria

- [ ] tests/scripts/test-cutover-tickets-migration.sh exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] bash -n syntax check passes on the test file
  Verify: bash -n $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] File contains test_cutover_phases_execute_in_order
  Verify: grep -q 'test_cutover_phases_execute_in_order' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] File contains test_cutover_creates_log_file_with_timestamp
  Verify: grep -q 'test_cutover_creates_log_file_with_timestamp' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] File contains test_cutover_dry_run_flag_produces_output_without_creating_state_file
  Verify: grep -q 'test_cutover_dry_run_flag_produces_output_without_creating_state_file' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] Tests FAIL before T2 implementation (RED state confirmed)
  Verify: { bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'FAIL\|not found\|No such file'; }


## Notes

**2026-03-23T00:59:16Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T00:59:31Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T01:00:10Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-23T01:00:14Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T01:00:27Z**

CHECKPOINT 5/6: Validation passed ✓ — tests confirmed RED (7 failures expected, script does not exist yet)

**2026-03-23T01:00:39Z**

CHECKPOINT 6/6: Done ✓ — all 6 AC pass; test file created at tests/scripts/test-cutover-tickets-migration.sh; RED state confirmed (7 failures: script not found)

**2026-03-23T01:05:54Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/scripts/test-cutover-tickets-migration.sh. Tests: 7 RED (expected). AC: all pass.
