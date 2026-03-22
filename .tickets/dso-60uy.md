---
id: dso-60uy
status: open
deps: [dso-ed01, dso-4uys]
links: []
created: 2026-03-22T03:53:47Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Add REVERT to ticket-lib.sh allowed event_type enum and create ticket-revert.sh

Extend ticket-lib.sh to allow REVERT events, and create ticket-revert.sh to write REVERT events.

Files to edit/create:
- Edit: plugins/dso/scripts/ticket-lib.sh — add REVERT to allowed event_type enum
- Create: plugins/dso/scripts/ticket-revert.sh

ticket-lib.sh change:
Change the event_type validation case from:
  CREATE|STATUS|COMMENT|LINK|UNLINK|SNAPSHOT|SYNC)
to:
  CREATE|STATUS|COMMENT|LINK|UNLINK|SNAPSHOT|SYNC|REVERT)

ticket-revert.sh implementation:
Usage: ticket revert <ticket_id> <target_event_uuid> [--reason=<text>]

Steps:
1. Validate ticket exists in .tickets-tracker/
2. Scan ticket dir for event file whose UUID matches target_event_uuid (glob *.json, parse each)
3. If not found: print 'Error: no event with UUID <uuid> found in ticket <id>' to stderr; exit 1
4. If found event is a REVERT: print 'Error: cannot revert a REVERT event' to stderr; exit 1
5. Extract target_event_type from the found event
6. Write REVERT event JSON:
   { event_type: 'REVERT', timestamp: <now UTC epoch>, uuid: <new UUIDv4>, env_id: <ENV_ID>, author: <git config user.email or 'unknown'>,
     data: { target_event_uuid: <target_uuid>, target_event_type: <type>, reason: <reason or ''> } }
7. Call write_commit_event (source ticket-lib.sh) to atomically write and commit the event

ENV_ID: read from .tickets-tracker/.env-id if exists, else generate and persist new UUID.

TDD Requirement: Task dso-ed01 (RED tests) must be RED before this task runs. After this task, test_ticket_revert_writes_revert_event, test_ticket_revert_rejects_revert_of_revert, test_ticket_revert_rejects_nonexistent_target must pass.

Run tests: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_revert_event.py::test_ticket_revert_writes_revert_event tests/scripts/test_revert_event.py::test_ticket_revert_rejects_revert_of_revert tests/scripts/test_revert_event.py::test_ticket_revert_rejects_nonexistent_target -v

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ticket-revert.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-revert.sh
- [ ] REVERT is accepted in ticket-lib.sh allowed event_type enum
  Verify: grep -q 'REVERT' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-lib.sh
- [ ] ticket-revert.sh writes a REVERT event with correct fields (event_type, target_event_uuid, target_event_type, reason)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_revert_event.py::test_ticket_revert_writes_revert_event -v
- [ ] ticket-revert.sh rejects REVERT-of-REVERT with non-zero exit and stderr message
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_revert_event.py::test_ticket_revert_rejects_revert_of_revert -v
- [ ] ticket-revert.sh rejects nonexistent target UUID with non-zero exit
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_revert_event.py::test_ticket_revert_rejects_nonexistent_target -v


## Notes

**2026-03-22T04:23:31Z**

CHECKPOINT 6/6: Done ✓ — impl complete, tests GREEN. BLOCKED: test gate hits pre-existing RED tests from w21-54wx epic (ticket-reducer, ticket-graph, etc.)
