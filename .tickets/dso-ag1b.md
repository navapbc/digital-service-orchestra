---
id: dso-ag1b
status: in_progress
deps: []
links: []
created: 2026-03-17T18:34:07Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-25
---
# Display Task titles during sprint batch execution

When sprint executes a batch of tasks, the task titles should be displayed, not just ticket numbers. Ticket numbers do not have meaning to the human observing the run.


## Notes

**2026-03-19T01:44:26Z**


## Context
When `/dso:sprint` executes a batch of tasks, the orchestrator displays only ticket IDs (e.g., `dso-abc1`) in its output — not human-readable titles. Developers observing a multi-task batch cannot determine what's running without looking up each ID separately. In long-running batches where output scrolls off the terminal, there is no persistent reference point. Since ticket titles are already loaded into the orchestrator's context at dispatch time, surfacing them costs no additional API calls. This epic covers two distinct display points in the sprint skill: the pre-launch batch header and the post-batch completion summary.

## Success Criteria
- Before each batch launches, the sprint orchestrator prints a numbered list of `[ID: Title]` pairs for all tasks in the batch
- After each batch completes, the completion summary includes each task's ID, title, and pass/fail status
- No additional `tk show` calls or ticket file reads are made beyond what sprint already performs at dispatch time
- A manual sprint run on a 2+ task epic confirms: (a) the pre-launch title list appears before any sub-agents are dispatched, and (b) the completion summary shows ID + title + pass/fail for each task

## Dependencies
dso-l2ct (Optimize /dso:sprint skill — prune bloat, merge phases, remove Task tracking) must complete first — this epic adds display instructions to the skill structure that dso-l2ct will establish.

## Approach
Add two prose instruction blocks to the `/dso:sprint` skill: one directing the orchestrator to print a title list before launching each batch, one directing it to include titles in the completion summary. Titles are already in context at dispatch time — no additional data fetching required.

