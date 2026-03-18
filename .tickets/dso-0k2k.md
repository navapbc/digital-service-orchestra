---
id: dso-0k2k
status: open
deps: []
links: []
created: 2026-03-17T18:34:29Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-36
---
# Ticket system upgrade

We have a collection of documents that describe an update to our ticketing system. We should rename our script because we have significantly diverged from tk. The update involves using an orphan branch and an event log to more effectively manage real time sync between worktrees on the same environment and near-realtime sync between sessions across environments. Our main pain points are conflicts merging and committing tickets, lack of awareness between simultaneous sessions, and data loss due to improper overwrites of tickets by other sessions. Our secondary concern is performance. The system must be able to comfortably handle 1000 open tickets as a max without running into exit code 144 timeouts (~73 second command time, but we should have a comfortable buffer to account for hooks).

