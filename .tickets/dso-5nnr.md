---
id: dso-5nnr
status: in_progress
deps: [dso-1a6u]
links: []
created: 2026-03-21T16:32:42Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-05z9
---
# Call detect_newly_unblocked after conflict resolution in sync path

After conflict resolution resolves a ticket's STATUS to 'closed', call detect_newly_unblocked() from ticket-unblock.py and emit UNBLOCKED output in sync command output.

TDD Requirement: This task adds behavioral content (conditional unblock check after sync resolution). Write a RED test first.
Test file: tests/scripts/test_ticket_reducer_conflict.py
Test to add: test_sync_calls_unblock_after_conflict_resolution_to_closed — mock detect_newly_unblocked, simulate conflict resolution where winning status is 'closed', assert detect_newly_unblocked is called with the closed ticket ID and event_source='sync-resolution'.
Run: python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_sync_calls_unblock_after_conflict_resolution_to_closed -q and confirm failure before implementation.

Implementation steps:
1. After T5a (strategy applied), check if the winning resolved status for any ticket is 'closed'
2. Collect all ticket IDs resolved to 'closed' in this sync operation
3. Import detect_newly_unblocked from ticket-unblock.py (dso-3npm) via importlib
4. Call: newly_unblocked = detect_newly_unblocked(closed_ticket_ids, tracker_dir, event_source='sync-resolution')
5. For each unblocked ticket, emit: UNBLOCKED: <ticket_id> — same format as ticket-transition close output (w21-8011)
6. If no tickets resolved to closed, skip the unblock check entirely

Constraint: Use event_source='sync-resolution' (not 'local-close') to distinguish sync-triggered unblocks in logs.
Constraint: detect_newly_unblocked is only called when ≥1 ticket resolved to 'closed' in this sync pass.

Depends on: dso-1a6u (sync path must exist), dso-3npm (detect_newly_unblocked must be implemented)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] detect_newly_unblocked called with event_source='sync-resolution' after conflict resolves to closed
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_sync_calls_unblock_after_conflict_resolution_to_closed --tb=short -q
- [ ] UNBLOCKED output emitted for each newly unblocked ticket
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_sync_calls_unblock_after_conflict_resolution_to_closed --tb=short -q
- [ ] detect_newly_unblocked not called when no conflict resolved to closed
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_sync_no_unblock_when_not_closed --tb=short -q

