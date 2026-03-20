---
id: w21-qjcy
status: open
deps: [w21-2r0x]
links: []
created: 2026-03-20T15:46:08Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-bwfw
---
# As a developer, I can see bridge problems and recover from bad bridge actions


## Notes

**2026-03-20T15:47:23Z**

## Description
**What**: Bridge observability and recovery: BRIDGE_ALERT events, bridge-status command, bridge-fsck audit, REVERT events with check-before-overwrite.
**Why**: Without visibility into bridge problems, failures are silent. Without recovery, bad state requires manual event surgery.
**Scope**:
- IN: BRIDGE_ALERT event type, passive health warning in ticket show/list, ticket bridge-status command, ticket bridge-fsck (mapping audit, orphans, duplicates, stale SYNC), REVERT events (undo bad bridge actions), REVERT check-before-overwrite (fetch Jira state before pushing revert)
- OUT: bridge-fsck --deep mode (future: field-level Jira comparison)

## Done Definitions
- BRIDGE_ALERT events trigger a health warning in ticket show/list output ← Satisfies SC7
- ticket bridge-status shows last run time, success/failure, unresolved conflicts ← Satisfies SC7
- ticket bridge-fsck audits mappings, detects orphans/duplicates/stale SYNC events ← Satisfies SC7
- REVERT events undo specific bridge actions; outbound REVERT checks Jira state before pushing and emits BRIDGE_ALERT if Jira has diverged ← Satisfies SC7 + adversarial review
- REVERT behavior for comment records is explicitly defined: orphaned Jira comments are accepted as known post-REVERT state requiring manual cleanup ← adversarial review
- Unit tests passing

## Considerations
- [Reliability] REVERT + comment interaction: reverting a ticket with synced comments leaves Jira comments orphaned — document as expected behavior
- [Maintainability] REVERT-of-REVERT is rejected by CLI (REVERTs target non-REVERT events only)

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. High confidence means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.
