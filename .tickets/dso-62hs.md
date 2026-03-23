---
id: dso-62hs
status: in_progress
deps: [dso-gfph]
links: []
created: 2026-03-23T03:58:10Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-7mlx
---
# RED: Write failing tests for _phase_migrate in cutover migration script

Write failing tests for the _phase_migrate phase implementation in plugins/dso/scripts/cutover-tickets-migration.sh. The current stub only prints 'Running phase: migrate' with no actual behavior.

TDD REQUIREMENT: Append 5 failing tests to tests/scripts/test-cutover-tickets-migration.sh. All must FAIL (RED) before Task 4 begins.

Tests to write (all use temp fixture directories via _setup_fixture):

1. test_phase_migrate_creates_ticket_events
   Setup: temp fixture with initialized tracker worktree (call ticket-init.sh on the fixture). Create 2 .tickets/*.md files with known IDs, titles, and open status. Set CUTOVER_TICKETS_DIR and CUTOVER_TRACKER_DIR env vars to fixture paths.
   Run: full cutover run on fixture.
   Assert: event CREATE JSON exists for each migrated ticket under fixture tracker dir; ticket IDs preserved as directory names.
   RED: fails because _phase_migrate stub creates no event files.

2. test_phase_migrate_is_idempotent
   Setup: fixture with 1 .tickets/*.md and initialized tracker. Run migration once. Then run again with fresh state (delete state file).
   Assert: exactly 1 CREATE event file per ticket (not duplicated); exit 0 both runs.
   RED: fails because stub creates nothing.

3. test_phase_migrate_skips_malformed_tickets
   Setup: fixture with 1 valid .tickets/*.md and 1 malformed file (no --- frontmatter delimiters).
   Run: full migration on fixture.
   Assert: exit 0; valid ticket has CREATE event; malformed ticket has no CREATE event; combined output contains skip/malformed indicator.
   RED: fails because stub creates no events.

4. test_phase_migrate_preserves_notes_with_timestamps
   Setup: fixture with 1 .tickets/*.md whose Notes section has a timestamped note with special chars (dollar sign, ampersand, angle brackets).
   Run: full migration.
   Assert: COMMENT event JSON exists; python3 json.load of that file returns body field containing the note text.
   RED: fails because stub creates no events.

5. test_phase_migrate_disables_compaction
   Setup: inspect the script source.
   Assert: grep -q 'TICKET_COMPACT_DISABLED' plugins/dso/scripts/cutover-tickets-migration.sh
   This test asserts on source content, passes once implementation adds the export. Structural RED test.
   RED: fails because stub does not reference TICKET_COMPACT_DISABLED.

Note on CUTOVER_TICKETS_DIR: the migrate phase needs a new env var (CUTOVER_TICKETS_DIR, default: REPO_ROOT/.tickets) to locate the source tickets directory. Tests must set this to the fixture .tickets/ dir.

Note on CUTOVER_TRACKER_DIR: the migrate phase needs a new env var (CUTOVER_TRACKER_DIR, default: REPO_ROOT/.tickets-tracker) to locate the destination tracker dir. Tests must set this to the fixture tracker dir.

File to edit: tests/scripts/test-cutover-tickets-migration.sh

## Acceptance Criteria

- [ ] bash tests/scripts/test-cutover-tickets-migration.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-cutover-tickets-migration.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] 5 new test functions for migrate phase exist in test-cutover-tickets-migration.sh
  Verify: grep -c 'test_phase_migrate' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh | awk '{exit ($1 < 5)}'
- [ ] All 5 new migrate tests FAIL before Task 4 implementation (RED state)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'FAIL.*migrate'


## Notes

<!-- note-id: nhqgt49o -->
<!-- timestamp: 2026-03-23T05:07:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 6gf6pjk5 -->
<!-- timestamp: 2026-03-23T05:08:02Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — test file uses _setup_fixture helper, assert_eq/assert_ne/assert_contains/assert_pass_if_clean from assert.sh, runs cutover script via bash with env vars, pattern: setup → run → assert → rm -rf fixture

<!-- note-id: 1o79ri8b -->
<!-- timestamp: 2026-03-23T05:09:11Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ — appended 5 test functions (test_phase_migrate_creates_ticket_events, test_phase_migrate_is_idempotent, test_phase_migrate_skips_malformed_tickets, test_phase_migrate_preserves_notes_with_timestamps, test_phase_migrate_disables_compaction) after existing tests, before print_summary

<!-- note-id: 8o6rt625 -->
<!-- timestamp: 2026-03-23T05:09:15Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — tests ARE the implementation for this RED task (TDD RED phase)

<!-- note-id: q9638yaz -->
<!-- timestamp: 2026-03-23T05:10:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — bash syntax valid; all 5 migrate tests FAIL (RED): test_phase_migrate_creates_ticket_events, test_phase_migrate_is_idempotent, test_phase_migrate_skips_malformed_tickets, test_phase_migrate_preserves_notes_with_timestamps, test_phase_migrate_disables_compaction; ruff check + format --check pass

<!-- note-id: jwmui8io -->
<!-- timestamp: 2026-03-23T05:10:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — AC self-check: (1) test suite runs (exits 1 as expected — RED task, 5 new migrate tests intentionally fail); (2) ruff check PASS; (3) ruff format --check PASS; (4) 25 test_phase_migrate refs >= 5 PASS; (5) grep 'FAIL.*migrate' confirms all 5 new tests fail RED PASS. No discovered work requiring new tickets.
