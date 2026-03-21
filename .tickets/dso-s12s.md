---
id: dso-s12s
status: open
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

