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

<!-- note-id: iomxwdu9 -->
<!-- timestamp: 2026-03-22T23:02:09Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: mechanical (doc/prompt update only), Score: 2 (Tier 1 mechanical). Prior fix (9166151) updated SUB-AGENT-BOUNDARIES.md only; task-execution.md line 23 still uses '-t task' for discovered bugs. fix-task-tdd.md and fix-task-mechanical.md are deprecated (forward to /dso:fix-bug); test-failure-fix.md rules section says 'create a ticket task' without -t bug flag.

<!-- note-id: sbulogor -->
<!-- timestamp: 2026-03-22T23:03:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fix complete. Root cause: commit 9166151 only updated SUB-AGENT-BOUNDARIES.md permitted actions; task-execution.md (the actual sub-agent prompt template) still had '-t task' in both the discovered-work example (step 8) and the Rules section. Fixed: (1) task-execution.md step 8 example now uses '-t bug'; (2) Rules section now says 'tk create -t bug --parent=<parent-id>'. Tests: added TestTaskExecutionDiscoveredBugType class to tests/skills/test_task_execution_template.py (RED→GREEN). 282 tests pass. fix-task-tdd.md and fix-task-mechanical.md are deprecated (forward to /dso:fix-bug) so no change needed there.
