---
id: dso-9p30
status: open
deps: [dso-bdk5, dso-sroj]
links: []
created: 2026-03-23T17:34:49Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-k4sw
---
# Add closed-parent guard to ticket-link.sh for depends_on


## Notes

**2026-03-23T17:35:42Z**

## Description
Add closed-parent guard to ticket-link.sh. In _write_link_event(), after validating both tickets exist, add: if relation='depends_on' AND target ticket status is 'closed' (via ticket_read_status on target_id, NOT source_id), exit 1 with error. Other relation types (relates_to, blocks) pass through unchanged.

Note: _write_link_event is called for reciprocal relates_to links — guard must only fire when relation=depends_on.

