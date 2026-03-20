---
id: w21-goqp
status: open
deps: []
links: []
created: 2026-03-20T05:07:35Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-54wx
---
# As a developer, agents are prevented from directly editing ticket event files


## Notes

**2026-03-20T05:09:31Z**

## Description
**What**: PreToolUse hook that blocks Edit/Write/Bash modifications to .tickets-tracker/ files. Redirects agents to ticket commands. Allowlist for ticket CLI patterns.
**Why**: The event sourcing model requires writes go through ticket commands to maintain invariants. Direct edits would corrupt the event log.
**Scope**:
- IN: PreToolUse hook, pattern matching on command strings, allowlist for ticket CLI commands (ticket create, ticket sync, etc.), redirect error message
- OUT: Blocking Read access (intentionally allowed for debugging)

## Done Definitions
- PreToolUse hook blocks Edit/Write/Bash modifications targeting .tickets-tracker/ ← Satisfies SC8
- Ticket CLI commands (ticket *) are allowlisted and not blocked ← Satisfies SC8
- Blocked attempts show clear error message redirecting to ticket commands ← Satisfies SC8
- Unit tests passing

## Considerations
- [Maintainability] Hook must pattern-match on command strings — use allowlist approach (block all .tickets-tracker/ references except ticket * commands)

**Escalation policy**: Proceed unless a significant assumption is required to continue. Escalate only when genuinely blocked. Document all assumptions.
