---
id: w21-gykt
status: open
deps: [w21-8cw2]
links: []
created: 2026-03-20T15:46:08Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-bwfw
---
# As a developer, Jira changes are automatically pulled into my local ticket system


## Notes

**2026-03-20T15:46:47Z**

## Description
**What**: Scheduled GitHub Actions trigger that queries Jira for recently updated issues, normalizes timestamps to UTC, imports Jira-originated tickets, and writes inbound events with bridge environment ID.
**Why**: Enables bidirectional sync — Jira changes (including tickets created directly in Jira) are reflected locally.
**Scope**:
- IN: Schedule trigger, JQL windowed pull with configurable overlap buffer, timezone-aware parsing to UTC, Jira-originated ticket import as CREATE events, configurable status/type mapping, unmapped values write BRIDGE_ALERT
- OUT: Comment sync (w21-dww7), hardening details (w21-2r0x)

## Done Definitions
- Scheduled workflow queries Jira using JQL updatedDate with configurable overlap buffer against stored UTC last_pull_timestamp ← Satisfies SC2, SC3
- All inbound Jira timestamps parsed timezone-aware and converted to UTC epoch ← Satisfies SC2
- Tickets created directly in Jira are imported as new local CREATE events with bridge environment ID ← Satisfies SC5
- Status/type mappings are configurable; unmapped values rejected with BRIDGE_ALERT event ← Satisfies SC5
- Jira service account timezone verified as UTC at workflow startup ← Satisfies SC2
- Unit tests passing

## Considerations
- [Reliability] Service account timezone must be UTC — startup health check verifies
- [Performance] Inbound at 1000+ Jira issues — JQL pagination + batch processing needed
- [Testing] External Jira dependency — need mock ACLI or Jira sandbox for testing

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. High confidence means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.
