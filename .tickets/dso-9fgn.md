---
id: dso-9fgn
status: open
deps: []
links: []
created: 2026-03-17T18:33:45Z
type: epic
priority: 3
assignee: Joe Oakhart
jira_key: DIG-11
---
# Limit tool use by sub-agents

Non-code review sub-agents should be limited to read only operations. Code review sub-agents must be able to write their findings and perform read operations freely, but should be restricted from write git commands. Implementation sub-agents should be prohibited from using commit or merge commands. Investigation and research sub-agents should have read only access. Examine logs of current sub-agent tool use to validate that these restrictions should not break existing workflows.

