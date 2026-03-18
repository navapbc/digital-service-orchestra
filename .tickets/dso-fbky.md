---
id: dso-fbky
status: open
deps: []
links: []
created: 2026-03-17T18:33:43Z
type: epic
priority: 3
assignee: Joe Oakhart
jira_key: DIG-10
---
# Add full autonomous mode session override

Create a skill called enable-full-auto. This skill should touch a file in the worktree called .full-auto-enabled. This file should be included in .gitignore. When this file is present in the worktree, any user escalation or approval should be handled by an opus sub-agent. This sub-agent is authorized to approve operations that would normally require user approval. We should create a prompt file for this agent that contains guidelines for being a careful steward of the project. The sub-agent should be skeptical of proposals, require additional information or investigation when its confidence is not high, and consider the impact of approval to the project beyond the current bug or feature.

