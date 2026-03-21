---
id: dso-9zsh
status: open
deps: []
links: []
created: 2026-03-19T16:54:02Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-48
---
# Make sprint skill aware of ticket type

Sprint handles epics well, routing them appropriately according to complexity. We should revisit how sprint handles tickets that are stories, tasks, or bugs. For bugs, sprint should exit and run our bug fix skill. Stories should route to implementation-plan. Tasks should skip breakdown, but be subject to the rest of our sprint safeguards.

