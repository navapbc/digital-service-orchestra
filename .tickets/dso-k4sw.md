---
id: dso-k4sw
status: closed
deps: [w21-wbqz]
links: []
created: 2026-03-23T17:06:44Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-24kl
---
# As a developer, ticket CLI commands enforce ticket health (closed-parent, bug-close-reason, open-children) without hook-based command parsing


## Notes

**2026-03-23T17:06:54Z**


## Context
The current hook-based guards (hook_bug_close_guard in pre-bash-functions.sh and closed-parent-guard.sh) parse Bash commands via regex to detect ticket operations and enforce health rules. This approach is fragile — it fires on false-positive patterns (e.g., blocking ticket reopens, matching all relation types) and requires duplicating v3 event-reading logic in hooks. Moving the guards into the CLI commands themselves eliminates regex parsing entirely since the commands already have parsed arguments, ticket type, and status available.

## Success Criteria
1. ticket transition <id> <current> closed on a bug-type ticket without --reason="Fixed: ..." or --reason="Escalated to user: ..." exits non-zero with an instructive error message.
2. ticket transition <id> <current> closed on a ticket with open children exits non-zero, listing the open children and instructing the agent to close them first.
3. ticket create <type> <title> <parent-id> where the parent is closed exits non-zero with an instructive error.
4. ticket link <child> <parent> depends_on where the parent is closed exits non-zero with an instructive error. Other relation types (relates_to, blocks) are not affected.
5. hook_bug_close_guard is removed from pre-bash-functions.sh and closed-parent-guard.sh is deleted. Their hook registrations are removed.
6. All new guard logic has unit tests covering both the blocking and allow paths.

## Approach
CLI-native guards with shared helper. Add a shared ticket_read_status() function to ticket-lib.sh that reads ticket status from the v3 event store. Add guard logic directly into ticket-transition.sh (bug-close reason + open-children check), ticket-create.sh (closed parent check), and ticket-link.sh (closed parent check for depends_on only). Remove both hooks entirely.

## Dependencies
None (parent story w21-wbqz other tasks dso-1cje/dso-hu14 are independent)

