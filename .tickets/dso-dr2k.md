---
id: dso-dr2k
status: in_progress
deps: [dso-710r, dso-pjcl]
links: []
created: 2026-03-23T00:24:23Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2a9w
---
# RED: Write failing tests for cutover idempotent resume from state file

TDD RED phase: append failing idempotent resume tests to tests/scripts/test-cutover-tickets-migration.sh.
Tests must FAIL before T6 implementation.

1. test_cutover_state_file_written_after_each_phase
   Setup: temp git repo, set CUTOVER_STATE_FILE to a temp path.
   Run script to completion with all stubs succeeding.
   Assert: state file exists and contains all 5 phase names (one per line or JSON array).

2. test_cutover_resume_skips_completed_phases
   Setup: temp git repo. Pre-write a state file indicating PRE_FLIGHT and MIGRATE completed.
   Run script with --resume flag (or CUTOVER_STATE_FILE pointing to existing state).
   Assert: output does NOT contain 'Running phase: PRE_FLIGHT' or 'Running phase: MIGRATE'.
   Assert: output DOES contain 'Skipping completed phase: PRE_FLIGHT' (or equivalent).
   Assert: output DOES contain 'Running phase: VALIDATE' (resumes from third phase).

3. test_cutover_resume_does_not_rerun_already_completed_phase
   Setup: temp git repo. Pre-write state file showing ALL phases completed.
   Run script with --resume.
   Assert: output contains 'All phases already completed' or similar; exit 0.
   Assert: no phase was re-executed (no 'Running phase:' lines in output).

Append to existing test file — do NOT overwrite T1 or T3 tests.

## Acceptance Criteria

- [ ] File contains test_cutover_resume_skips_completed_phases
  Verify: grep -q 'test_cutover_resume_skips_completed_phases' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] File contains test_cutover_state_file_written_after_each_phase
  Verify: grep -q 'test_cutover_state_file_written_after_each_phase' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] File contains test_cutover_resume_does_not_rerun_already_completed_phase
  Verify: grep -q 'test_cutover_resume_does_not_rerun_already_completed_phase' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] Syntax check passes on test file
  Verify: { SYNTAX_OK=0; bash -n $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>/dev/null && SYNTAX_OK=1; test $SYNTAX_OK -eq 1; }
- [ ] New resume tests FAIL before T6 implementation (RED state)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'FAIL.*resume\|FAIL.*state_file'


## Notes

<!-- note-id: on9z7x08 -->
<!-- timestamp: 2026-03-23T02:54:19Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: rjtszy5j -->
<!-- timestamp: 2026-03-23T02:54:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — cutover script uses PHASES array (validate/snapshot/migrate/verify/finalize), _state_append_phase() writes JSON state file, no --resume flag yet. Test file uses _setup_fixture(), assert_eq/assert_ne/assert_contains, _snapshot_fail/_pass_if_clean pattern.

<!-- note-id: m6u5jm1u -->
<!-- timestamp: 2026-03-23T02:55:21Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ — appended test_cutover_state_file_written_after_each_phase, test_cutover_resume_skips_completed_phases, test_cutover_resume_does_not_rerun_already_completed_phase to tests/scripts/test-cutover-tickets-migration.sh

<!-- note-id: 0hjlz3vy -->
<!-- timestamp: 2026-03-23T02:55:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — RED tests are the deliverable for this task

<!-- note-id: fnjopg6b -->
<!-- timestamp: 2026-03-23T02:56:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — bash -n syntax: OK; resume tests FAIL as expected (RED state); grep pattern 'FAIL.*resume|FAIL.*state_file' matches 7 lines

<!-- note-id: 12i5dz5u -->
<!-- timestamp: 2026-03-23T02:56:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All 5 AC pass. Tests written and confirmed RED. No discovered out-of-scope work.
