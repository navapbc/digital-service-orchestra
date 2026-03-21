---
id: dso-d08c
status: open
deps: [dso-xjzd]
links: []
created: 2026-03-21T04:57:53Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# Implement ticket-comment.sh (append COMMENT event via ticket-lib.sh with ghost check)

Create plugins/dso/scripts/ticket-comment.sh that appends a COMMENT event to a ticket and auto-commits it.

Usage: ticket comment <ticket_id> <body>

File: plugins/dso/scripts/ticket-comment.sh

Implementation:

Source ticket-lib.sh for write_commit_event.

Step 1 — Validate arguments:
  - ticket_id and body are required; if missing: print usage + exit 1
  - body must be non-empty: if empty string: print 'Error: comment body must be non-empty' + exit 1

Step 2 — Ghost check:
  - Verify TRACKER_DIR/<ticket_id>/ exists, else: print error + exit 1
  - Verify at least one *-CREATE.json exists in the dir, else: print 'Error: ticket <id> has no CREATE event' + exit 1

Step 3 — Build COMMENT event JSON via python3:
  {
    'timestamp': <UTC epoch int>,
    'uuid': <UUID4>,
    'event_type': 'COMMENT',
    'env_id': <from .env-id>,
    'author': <git user.name>,
    'data': {
      'body': <body string>
    }
  }
  Write to a temp file inside TRACKER_DIR (same filesystem as final location).

Step 4 — Call write_commit_event <ticket_id> <temp_event_path>

Step 5 — Output: print the COMMENT event UUID to stdout (for reference), or print nothing and just exit 0.

No flock needed outside write_commit_event — the flock is already handled inside ticket-lib.sh write_commit_event for the write+commit pipeline.

TDD Requirement: Run tests/scripts/test-ticket-comment.sh. All tests from dso-xjzd must pass (GREEN) after this task.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] plugins/dso/scripts/ticket-comment.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-comment.sh
- [ ] All tests from dso-xjzd pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-comment.sh
- [ ] Ghost prevention: script verifies CREATE event exists before writing COMMENT
  Verify: grep -q 'CREATE.json\|CREATE event' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-comment.sh
- [ ] COMMENT event JSON contains event_type='COMMENT' and data.body field
  Verify: grep -q 'COMMENT' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-comment.sh && grep -q 'body' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-comment.sh

