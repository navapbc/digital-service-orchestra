---
id: dso-t7af
status: open
deps: []
links: []
created: 2026-03-17T18:33:30Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-3
---
# Remove 5-sub-agent cap for orchestration

Right now we use a fixed 5-agent cap on sub-agents unless we are close to our usage limit, in which case we only allow 1. We want to modify this logic to scale with available session usage relative to the limit imposed by Anthropic that resets every ~6 hours. The maximum number of concurrent sub-agents should be calculated using the following formula: 10 - (current season usage percent / 10). If the session usage is 4%, the maximum number of sub-agents should be 10. If it's 48%, the maximum number of agents should be 5. If it's 85%, the maximum number of agents should be 1. And after 95%, the orchestrator should complete any pending commit and merge actions, then gracefully pause. This should apply to both the sprint skill and the debug everything skill. The cap on opus agents should scale as a function of the cap on all sub-agents. Up to 30% of available agents may be opus agents. The session usage limit this epic is referring to is the same limit shown by /usage.  It is retrieved using an Anthropic API call. It is NOT the same as the current session's context window usage.

