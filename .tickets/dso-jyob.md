---
id: dso-jyob
status: open
deps: [dso-bdk5, dso-sroj]
links: []
created: 2026-03-23T17:34:49Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-k4sw
---
# Add bug-close-reason and open-children guards to ticket-transition.sh


## Notes

**2026-03-23T17:35:42Z**

## Description
Add guard logic to ticket-transition.sh. CRITICAL: guard logic must run INSIDE the Python flock block (lines 118-197), after reading state via the reducer but before building the STATUS event JSON. This matches the existing optimistic concurrency pattern.

When target_status='closed':
1. Read ticket type from reducer state. If type='bug', require --reason flag with 'Fixed:' or 'Escalated to user:' prefix. Exit 1 with instructive error if missing.
2. Call ticket_find_open_children. If any open children, exit 1 listing them with instruction to close children first.

Shell must parse --reason from remaining args before passing to Python block as additional sys.argv.

Also update plugins/dso/docs/ticket-cli-reference.md with --reason flag documentation.

