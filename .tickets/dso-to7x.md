---
id: dso-to7x
status: open
deps: []
links: []
created: 2026-03-17T18:33:52Z
type: epic
priority: 3
assignee: Joe Oakhart
jira_key: DIG-15
---
# Allow coding sub-agents to use worktree isolation

Right now we use claude-safe to create a worktree when we launch Claude. We want to update our workflow to take advantage of worktree isolation for sub-agents. Claude should no longer be launched with claude-safe. We should remove the hook that prevents sub-agents from using worktree isolation. We need to redesign our workflow, including orchestrators like sprint and debug everything skills, our commit and review workflows, and our hooks. Sub-agents make changes in their isolated worktrees. Right now they are instructed not to commit changes. How can we implement a similar review enforcement mechanism that will function with agent changes in separate worktrees? Should subagents commit their changes to their worktree? Do we need to re-enable the pre-compact hook that commits changes for sub-agents?

