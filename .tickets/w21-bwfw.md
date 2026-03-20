---
id: w21-bwfw
status: open
deps: [w21-54wx]
links: []
created: 2026-03-20T03:28:20Z
type: epic
priority: 1
assignee: Joe Oakhart
---
# Ticket system v3 — Jira bridge and LLM-optimized output

## Context
The ticket system needs to stay synchronized with Jira (the team's external project tracker) and provide token-efficient output for LLM agents. Currently, Jira sync requires local ACLI credentials, runs synchronously, and has known timezone bugs that cause missed updates and duplicate tickets. Moving the Jira bridge to GitHub Actions eliminates local dependencies and runs asynchronously. The bridge must handle bidirectional sync — including importing tickets created directly in Jira — without creating duplicates, gracefully merge Jira status changes, and protect against destructive operations. LLM-optimized output reduces token consumption for agent interactions.

## Success Criteria
1. A GitHub Actions workflow processes outbound events (git → Jira) on tickets branch push and inbound changes (Jira → git) on a configurable schedule. A concurrency group ensures only one bridge instance runs at a time. The workflow skips its own commits (identified by dedicated bridge git identity) to prevent infinite loops.
2. All timestamps normalized to UTC at the bridge boundary: ACLI JVM runs with -Duser.timezone=UTC, all inbound Jira timestamps parsed timezone-aware and converted to UTC epoch. Jira service account timezone must be UTC (documented as setup prerequisite).
3. Outbound sync uses git diff (current vs last-processed commit SHA) for new events. Inbound sync uses Jira updatedDate JQL with configurable overlap buffer (default 15 minutes) against a stored UTC last_pull_timestamp. Both markers checkpoint incrementally per batch, not just at end of run.
4. All bridge operations are idempotent. Before creating a Jira issue, the bridge searches for an existing issue with the local ticket ID as a marker — if found, maps instead of creating. Comments embed origin markers (event UUID as hidden HTML comment) to prevent duplication on round-trip. Outbound STATUS changes push the reducer's compiled state (post-conflict-resolution), not raw events.
5. Inbound Jira changes are written as bridge-authored events with a dedicated bridge environment ID, so Epic 2's conflict resolution handles Jira-vs-local conflicts naturally. Tickets created directly in Jira are imported as new local tickets with CREATE events. Status and type mappings are configurable; unmapped values are rejected and logged.
6. Destructive change protection: the bridge rejects inbound changes that would overwrite non-empty descriptions with empty, remove ticket relationships, or downgrade ticket types. Jira relationship rejections (e.g., schema disallows epic-blocks-epic) persist locally with jira_sync_status: "rejected" — the local relationship is never removed. The bridge fast-aborts on auth failure (401), preserving checkpoint.
7. Bridge problems are surfaced through three levels: (a) passive — ticket list/ticket show display a health warning when unresolved BRIDGE_ALERT events exist, (b) active — ticket bridge-status shows last run, failures, unresolved conflicts, (c) diagnostic — ticket bridge-fsck audits mappings, orphans, duplicates, stale SYNC events. REVERT events undo specific bad bridge actions.
8. ticket show --format=llm outputs minified single-line JSON with shortened keys, stripped nulls, no verbose timestamps — at least 50% token reduction. ticket list --format=llm outputs JSONL.
9. No local ACLI installation or Jira credentials required for developers. Bridge processes new outbound events within 5 minutes of push. Inbound changes reflected within schedule interval + processing time.

## Dependencies
w21-54wx (sync infrastructure + conflict resolution)

## Approach
Event-driven GitHub Actions workflow with concurrency group. ACLI with forced UTC. Idempotent operations with duplicate detection. Bridge events use dedicated environment ID. Configurable status/type mappings. Compiled-state outbound for STATUS. Origin markers for comment dedup. Destructive change guards. Incremental checkpointing. Three-level problem visibility (passive/active/diagnostic). REVERT events + bridge-fsck for recovery.

## Hardening (from scenario analysis)
- Concurrency group serializes bridge runs (no concurrent execution)
- Bridge git identity + commit-author check prevents infinite loops
- Verify-after-create confirms Jira issue exists before writing SYNC event
- Compiled state for outbound STATUS ensures conflict-resolved state reaches Jira
- Origin markers (UUID embed) in comments prevent duplication on round-trip
- Rejected Jira relationships persist locally, never removed
- Unmapped status/type rejected and logged (not silently passed through)
- Destructive change guards reject empty-over-non-empty, relationship removal, type downgrade
- Incremental checkpointing per batch survives runner timeouts
- Fast-abort on auth failure preserves checkpoint
- Jira-originated tickets imported as new local tickets
- REVERT events + bridge-fsck for recovery from bad state

## Timezone Handling
- ACLI JVM: -Duser.timezone=UTC
- Jira service account: timezone must be UTC (setup prerequisite)
- All inbound timestamps: parsed with timezone-aware Python dateutil, converted to UTC epoch
- JQL updatedDate: configurable overlap buffer (default 15 min) accounts for clock skew
- All stored timestamps in UTC
