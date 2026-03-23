---
id: dso-sroj
status: open
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

