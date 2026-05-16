# Jira Bridge Bidirectional Audit

**Generated:** 2026-05-15 (session worktree-20260515-201328)

## Scope

Comprehensive bidirectional audit of the Jira bridge after Cluster A/B/C fixes
land. Compares local DSO ticket state (source of truth per user directive) to
Jira state for each ticket that has a `jira_key` sidecar.

## Per-Field Test Coverage Matrix (existing unit + integration tests)

Source: `tests/scripts/test_bridge_*_field_coverage.py`, `test_bridge_round_trip.py`.

| Field          | Inbound (Jira→Local) | Outbound (Local→Jira) | Round-trip |
|----------------|----------------------|------------------------|------------|
| title          | TestInboundTitle     | TestOutboundTitle      | covered    |
| description    | TestInboundDescription | TestOutboundDescription | covered  |
| status         | TestInboundStatus    | TestOutboundStatus     | covered    |
| priority       | TestInboundPriority  | TestOutboundPriority   | covered    |
| assignee       | TestInboundAssignee  | TestOutboundAssignee   | covered    |
| ticket_type    | TestInboundTicketType | TestOutboundTicketType | covered   |
| comment        | TestInboundComment   | TestOutboundComment    | covered    |
| tags/labels    | TestInboundTags      | TestOutboundEditTags   | covered    |
| parent_id      | TestInboundParentId  | TestOutboundEditParentId | covered  |
| blocks link    | TestInboundBlocksLinks | TestOutboundLink     | covered    |
| supersedes     | TestInboundSupersedesPrecedence + TestOutboundSupersedesAsRelates | | covered |

**Coverage gaps** (no per-field unit test currently exists):
- `resolutiondate` (read-only field; inbound captures it, no outbound)
- `created` (timestamp; informational only)
- `updated` (timestamp; drives cursor — covered indirectly by cursor tests)

## Cluster Fixes Landed This Session

| Cluster | Bug | Fix commit | Test |
|---------|-----|------------|------|
| A — inbound cursor watermark | 77c3-8906, jira-dig-2564 | 2bdbb2d2e3 | TestProcessInboundCursorReliability (3 tests) |
| B — outbound STATUS replay dedup | 487d-ce11 | 978bd24341 | TestOutboundStatusMissingSyncDedup |
| C — onboarding Jira docs | 2f7c-9c91, jira-dig-2561 | 6328499da4 | doc-only (no executable test, per LLM-behavioral exemption) |

## Live Audit Results (2026-05-15 session)

Audit script: `/tmp/jira-audit.py` (kept out-of-tree; reusable for follow-up reconciliation epic).
Sample: 30 jira-linked local tickets pulled from a population of 1408 SYNC files
on the tickets branch.

| Metric | Value |
|--------|-------|
| Total jira-linked local tickets (population) | 1408 |
| Sampled | 30 |
| Discrepancies | 3 (~10%) |
| Local-read errors | 24 |
| Closed-local-but-open-Jira | 0 |

### Discrepancies (local status wins)

| Local ID | Jira key | Field | Local (truth) | Jira (current) | Action |
|----------|----------|-------|---------------|----------------|--------|
| 00c5-87a7 | DIG-2531 | status | archived | Done (closed) | None — equivalent terminal state |
| 0180-e680 | DIG-2570 | status, title, issuetype | archived / "As a DSO maintainer..." / story | Done / "[0180-e680...]" / task | Emit EDIT (title + type) — defer to reconciliation epic e7d6-8013 |
| 023d-2d40 | DIG-2571 | status, title, issuetype | archived / "[ticket-cli]: ticket show/transition..." / bug | Done / "[023d-2d40...]" / task | Emit EDIT (title + type) — defer to reconciliation epic e7d6-8013 |

**Pattern:** historical CREATEs landed on Jira with bare `[local-id]` placeholder
titles and default `task` issuetype. The `bridge-reconcile-types.py` one-shot
already handles type/priority; a similar one-shot is needed for title backfill.

### Local-read errors

24/30 ticket-show invocations failed (10s timeout). Concentrated on `jira-dig-*`
IDs — these tickets exist on the tickets branch but the local CLI cannot resolve
them. Same symptom as `jira-dig-2564`/`jira-dig-2561` in this session's
investigation. This is a separate CLI-resolution bug — file as follow-up.

## Action Items (assigned to reconciliation epic e7d6-8013)

1. **Run inbound INBOUND_BACKFILL** to recover DIG-2500+ issues missed before the
   cursor fix. With the watermark fix landed, the backfill is now safe — every
   issue it re-fetches is either CREATEd or dead-lettered.
2. **Write a title+issuetype reconciliation one-shot** (modeled on
   `bridge-reconcile-types.py`) to emit EDIT events for the ~10% of jira-linked
   tickets where Jira shows placeholder title / default type.
3. **File CLI bug** for `dso ticket show jira-dig-*` resolution failures.
4. **Scheduled audit cron** — add `bridge-audit.py` to the bridge package +
   schedule weekly via GitHub Actions.

## CI Verification Plan

After this branch lands on main, the next runs of:
- `.github/workflows/inbound-bridge.yml` — exercises cursor watermark + dead-letter
- `.github/workflows/outbound-bridge.yml` — exercises BRIDGE_ALERT dedup

provide live verification of all 3 cluster fixes against the real Jira project.
Failure-to-converge from prior runs (the unbounded BRIDGE_ALERT replay on
0585-c734 and 0b63-132b) should stop after the first post-fix outbound run.
