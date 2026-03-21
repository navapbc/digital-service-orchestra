---
id: dso-7svw
status: closed
deps: [dso-t561]
links: []
created: 2026-03-21T04:57:32Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# Implement ticket-transition.sh (flock-serialized STATUS event with optimistic concurrency and ghost check)

Create plugins/dso/scripts/ticket-transition.sh that transitions a ticket's status with optimistic concurrency control and ghost ticket prevention.

Usage: ticket transition <ticket_id> <current_status> <target_status>

File: plugins/dso/scripts/ticket-transition.sh

Implementation:

Source ticket-lib.sh for write_commit_event.

Step 1 — Ghost check (before acquiring flock):
  - Verify TRACKER_DIR/<ticket_id>/ exists, else: print error + exit 1
  - Verify at least one *-CREATE.json file exists in the dir, else: print 'Error: ticket <id> has no CREATE event' + exit 1

Step 2 — Validate arguments:
  - Validate current_status and target_status are in: open, in_progress, closed, blocked
  - If current_status == target_status: print 'No transition needed' and exit 0

Step 3 — Acquire flock and read-verify-write:
  All of the following must happen inside the flock (same pattern as write_commit_event):
  a. Run python3 ticket-reducer.py to compile current state
  b. Extract actual current status from compiled state
  c. If actual_status != current_status: release lock, print actual status, exit 1
  d. Build STATUS event JSON via python3:
     {
       'timestamp': <UTC epoch int>,
       'uuid': <UUID4>,
       'event_type': 'STATUS',
       'env_id': <from .env-id>,
       'author': <git user.name>,
       'data': {
         'status': <target_status>,
         'current_status': <current_status>
       }
     }
  e. Call write_commit_event <ticket_id> <temp_event_path>

Important: The read-verify-write (steps a-e) must all occur while holding flock to prevent TOCTOU races between concurrent sessions.

TDD Requirement: Run tests/scripts/test-ticket-transition.sh. All tests from dso-t561 must pass (GREEN) after this task.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] plugins/dso/scripts/ticket-transition.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-transition.sh
- [ ] All tests from dso-t561 pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-transition.sh
- [ ] Optimistic concurrency: transition with wrong current_status exits non-zero and prints actual status
  Verify: grep -q 'current_status\|actual.*status' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-transition.sh
- [ ] Ghost prevention: script verifies CREATE event exists before proceeding
  Verify: grep -q 'CREATE.json\|CREATE event' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-transition.sh
- [ ] Read-verify-write occurs inside flock (python3 fcntl.flock pattern)
  Verify: grep -q 'fcntl.flock\|flock\|LOCK_EX' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-transition.sh

## Notes

<!-- note-id: 1vlapzgn -->
<!-- timestamp: 2026-03-21T05:49:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: jcc1t6yj -->
<!-- timestamp: 2026-03-21T05:49:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 9iu704ri -->
<!-- timestamp: 2026-03-21T05:49:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (pre-existing) ✓

<!-- note-id: c798hkgy -->
<!-- timestamp: 2026-03-21T05:50:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: e1ldwwmc -->
<!-- timestamp: 2026-03-21T05:50:47Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: All tests pass — transition (20/20), init (14/14), create (13/13), shellcheck clean ✓

<!-- note-id: owepe8p8 -->
<!-- timestamp: 2026-03-21T05:50:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

**2026-03-21T05:53:45Z**

CHECKPOINT 6/6: Done ✓ — ticket-transition.sh implemented. Tests: 20 passed, 0 failed.
