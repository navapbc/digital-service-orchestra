---
id: dso-4lfo
status: closed
deps: []
links: []
created: 2026-03-19T16:53:52Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-45
---
# Incorporate a specialized Claude debugging workflow into our skill that fixes bugs

Our current workflows handle application bugs, but they aren't designed to handle bugs in our Claude Code workflow. We should a separate branch in our debugging skill logic that handles tracing gaps in our workflow by examining Claude skills, hooks, and prompts. This Claude debugging logic should specialize in agent behavior (e.g. using positive direction rather than negative blocks). It should be aware of context limitations and how agents respond to both low context and compacting. It should have context on context engineering and prompt engineering best practices and an expert knowledge of Claude Code behavior. We should probably create this as a separate sub-agent prompt that our debugging skill can use for these issues.

