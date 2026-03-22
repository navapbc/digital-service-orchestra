---
id: dso-pcgh
status: open
deps: []
links: []
created: 2026-03-22T17:37:26Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# Sub-agents create tickets with type 'task' instead of 'bug' when tracking discovered bugs


## Notes

<!-- note-id: 6dknvx6x -->
<!-- timestamp: 2026-03-22T17:37:35Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

When sub-agents discover bugs during sprint or debug-everything execution and create tracking tickets (per CLAUDE.md rule 'Always Do #9: search for the same anti-pattern elsewhere'), they use the default ticket type 'task' instead of 'bug'. This means orphan bug tickets show up as tasks, making them harder to triage and filter. The fix should update the sub-agent prompt templates (task-execution.md, fix-task-tdd.md, fix-task-mechanical.md, and SUB-AGENT-BOUNDARIES.md) to explicitly instruct sub-agents to use '-t bug' when creating tickets for discovered bugs or anti-patterns.
