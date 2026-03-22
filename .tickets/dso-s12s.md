---
id: dso-s12s
status: in_progress
deps: []
links: []
created: 2026-03-17T18:34:06Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-24
---
# Generic agent invocations should be given descriptive names

Whenever a generic agent is invoked, it should be given a descriptive name. Skills should be updated with this guidance when they use generic sub-agents


## Notes

<!-- note-id: eu7lgcgx -->
<!-- timestamp: 2026-03-21T18:33:46Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Scope carve-out: complexity evaluator and conflict analyzer

The complexity evaluator (dso:complexity-evaluator) and conflict analyzer (dso:conflict-analyzer) are being extracted into dedicated plugin agents under epic dso-2j6u. This replaces their generic agent invocations with named agents entirely — descriptive naming for these two agents is resolved by dso-2j6u and should be excluded from this epic's scope.


<!-- note-id: 9o41c6eg -->
<!-- timestamp: 2026-03-22T17:10:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Context
When /dso:sprint or /dso:debug-everything dispatch sub-agents, the Agent tool's description parameter sometimes contains just a ticket ID (e.g., dso-abc1). This shows as Agent(dso-abc1) in the Claude Code status line, which tells the user nothing about what that agent is doing. The orchestrator already has the ticket title in context at dispatch time — it just isn't instructed to use it.

## Success Criteria
- Every prompt template in /dso:sprint and /dso:debug-everything that instructs the orchestrator to dispatch a sub-agent includes explicit guidance to derive the description field from the ticket title (3-5 word summary, no ticket ID)
- The guidance applies to all generic agent dispatches (not dedicated plugin agents like dso:complexity-evaluator, which are out of scope per the existing carve-out)
- A user watching the status line during a sprint or debug-everything run sees human-readable summaries like Agent(Fix review gate hash) instead of ticket IDs
- Validated by running a sprint or debug-everything session post-change and confirming that every sub-agent status line displays a human-readable task summary rather than a bare ticket ID

## Approach
Add prompt-level guidance to the dispatch templates in both orchestrator skills. No new scripts or runtime logic — the LLM already has the title in context and just needs the instruction.

