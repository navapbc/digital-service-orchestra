---
id: w20-9zaj
status: in_progress
deps: [w20-6dad]
links: []
created: 2026-03-21T16:32:35Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-6llo
---
# Implement sync-before-compact and remote SNAPSHOT skip in ticket-compact.sh

Implement sync-before-compact precondition in ticket-compact.sh. This task depends on w21-6k7v (ticket sync infrastructure) being complete. Implementation steps: (1) at the start of ticket-compact.sh (after threshold check passes), call 'ticket sync' via TICKET_SYNC_CMD env override (default: bash $SCRIPT_DIR/ticket sync); if sync returns non-zero, print error and exit non-zero, (2) after sync completes, check if the ticket's remote branch has any existing SNAPSHOT event: use 'git -C $TRACKER_DIR log origin/tickets --oneline -- $ticket_id/*-SNAPSHOT.json 2>/dev/null | head -1' to detect a remote SNAPSHOT; if found, print 'skipping compaction for $ticket_id — remote SNAPSHOT exists' and exit 0, (3) proceed with normal compaction if no remote SNAPSHOT detected. TICKET_SYNC_CMD env override allows test injection. Note: this task requires w21-6k7v's ticket sync subcommand to exist. If sync subcommand is absent at test time, test suite should skip gracefully. TDD Requirement: Run bash tests/scripts/test-compact-sync-precondition.sh — all 4 tests must pass GREEN.

## ACCEPTANCE CRITERIA

- [ ] bash tests/scripts/test-compact-sync-precondition.sh passes (all 4 tests GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-compact-sync-precondition.sh
- [ ] ticket-compact.sh calls sync before writing SNAPSHOT (sync invoked before flock section)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-compact-sync-precondition.sh
- [ ] ticket-compact.sh exits 0 with skip message when remote SNAPSHOT detected
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-compact-sync-precondition.sh
- [ ] ticket-compact.sh exits non-zero when sync returns non-zero
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-compact-sync-precondition.sh
- [ ] TICKET_SYNC_CMD env override respected (enables test injection)
  Verify: grep -q 'TICKET_SYNC_CMD' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-compact.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh

