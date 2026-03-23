---
id: dso-sroj
status: closed
deps: [dso-bdk5]
links: []
created: 2026-03-23T17:34:49Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-k4sw
---
# Add ticket_read_status and ticket_find_open_children to ticket-lib.sh


## Notes

**2026-03-23T17:35:42Z**

## Description
Add two shared helper functions to plugins/dso/scripts/ticket-lib.sh:

1. ticket_read_status <ticket_id> — reads ticket status from v3 event store using ticket-reducer.py. Returns status string (open/in_progress/closed/blocked). Computes TRACKER_DIR and REDUCER internally (do NOT rely on caller-set globals — ticket-create.sh does not set REDUCER).

2. ticket_find_open_children <ticket_id> — scans all tickets via reducer, finds tickets whose parent_id matches the given ticket_id and status is not 'closed'. Outputs one child ID per line.

Both functions follow existing ticket-lib.sh patterns. Use git rev-parse for TRACKER_DIR and BASH_SOURCE for REDUCER path.

## ACCEPTANCE CRITERIA

- [ ] ticket_read_status function exists in ticket-lib.sh
  Verify: grep -q "ticket_read_status()" plugins/dso/scripts/ticket-lib.sh
- [ ] ticket_find_open_children function exists in ticket-lib.sh
  Verify: grep -q "ticket_find_open_children()" plugins/dso/scripts/ticket-lib.sh
- [ ] ticket-lib.sh passes bash syntax check
  Verify: bash -n plugins/dso/scripts/ticket-lib.sh
- [ ] RED tests from dso-bdk5 for helpers now pass (GREEN)
  Verify: bash tests/scripts/test-ticket-health-guards.sh 2>&1 | grep -qi "passed"


**2026-03-23T18:28:02Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T18:28:14Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T18:28:15Z**

CHECKPOINT 3/6: Tests written (none required — RED tests exist) ✓

**2026-03-23T18:29:38Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T18:29:46Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-23T18:29:59Z**

CHECKPOINT 6/6: Done ✓
