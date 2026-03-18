---
id: dso-pxos
status: open
deps: []
links: []
created: 2026-03-17T18:33:49Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-13
---
# Update end-session to display a list of pre-existing failures encountered.

During end-session, before technical learnings, the agent should generate a list of failures the session encountered that were considered pre-existing or otherwise rationalized and not fixed. 
For each failure, the agent should answer the following questions: 
Did you observe the failure before or after changes were made on your worktree? If not, is this really a pre-existing failure?
Does a bug exist for the failure, as required by CLAUDE.md? If not, why didn't you create one?

