---
id: dso-xtcg
status: open
deps: []
links: []
created: 2026-03-18T04:37:01Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-igoj
---
# Document workflow-config.conf keys and environment variables used by hooks, scripts, and skills

As an engineer configuring DSO, I want every `workflow-config.conf` key and environment variable documented with a description and usage context so I can configure DSO without reading source code.

## Done Definition

- Every `workflow-config.conf` key documented with: description, accepted values, default, and which component uses it
- Every environment variable used by hooks, scripts, AND skills documented with: description, required/optional status, and usage context
  - Scope explicitly includes: CLAUDE_PLUGIN_ROOT, DSO_ROOT, and any vars consumed outside of hook scripts
- Reference documentation committed to `docs/` (file path TBD based on audit in Story A)

## Escalation Policy

**If at any point you lack high confidence in your understanding of the existing project setup — e.g., you are unsure whether a config key is still active, what a variable's expected values are, or which components consume a given env var — stop and ask the user before documenting. Err on the side of guidance over assumption. Incorrect reference documentation is worse than missing documentation: it actively misleads engineers during setup.**

