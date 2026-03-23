---
id: dso-62hs
status: open
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

