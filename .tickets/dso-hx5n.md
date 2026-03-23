---
id: dso-hx5n
status: open
deps: []
links: []
created: 2026-03-23T18:04:16Z
type: task
priority: 3
assignee: Joe Oakhart
---
# Update hooks and scripts to use ticket CLI commands instead of tk commands


## Notes

**2026-03-23T18:04:29Z**

Discovered while implementing dso-hu14 (docs/CLAUDE.md tk reference update). Files in plugins/dso/hooks/ and plugins/dso/scripts/ still use banned tk commands: closed-parent-guard.sh uses 'tk status', classify-task.sh uses 'tk show', dedup-tickets.sh uses 'tk close', issue-quality-check.sh uses 'tk add-note', issue-batch.sh and sprint-next-batch.sh use 'tk show', release-debug-lock.sh uses 'tk show'. These are outside the scope of dso-hu14. Requires coordinated update with hook behavioral changes per dso-yv90.
