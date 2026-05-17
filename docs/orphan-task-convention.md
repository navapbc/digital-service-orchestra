# Orphan-Task Convention

## Definition

An orphan task is a ticket created by the sprint orchestrator when the cycle-end arbiter issues a `DEFER` ruling for a review finding. These tickets capture review findings that are not BLOCK-worthy (would not prevent merging) but should not be silently dropped — they are deferred to a future sprint for re-evaluation.

Orphan tasks are intentionally parentless: they carry no `parent_id` and belong to no epic. This distinguishes them from accidentally-unlinked tasks.

## Required Tag

Every orphan task created via the DEFER ruling path MUST carry two tags:
- `orphan:deferred_review` — primary identifier for arbiter-created orphan tasks
- `origin:arbiter` — provenance marker indicating the ticket was created by the cycle-end arbiter

Both tags are required. The combination is what grants exemption from `validate-issues.sh` health warnings (see below).

## When Created (DEFER Ruling)

The orchestrator creates an orphan task when:
1. The cycle-end arbiter (`code-reviewer-arbiter`) has run at cycle boundary
2. A review finding receives a `DEFER` ruling (not `BLOCK`, not `DROP`)
3. The orchestrator calls:
   ```bash
   .claude/scripts/dso ticket create task \
     "Deferred review finding: <finding.rationale[:80]>" \
     --tags=orphan:deferred_review \
     --tags=origin:arbiter \
     --priority=3
   ```
4. The ticket ID is logged to the cycle ledger entry as `defer_tickets[finding_index]`

The full dispatch documentation is in `plugins/dso/docs/workflows/REVIEW-WORKFLOW.md` Step 4.75 (Post-Arbiter Ruling Processing).

## Lifecycle

| Stage | Action |
|-------|--------|
| **Created** | Status `open`, no parent, tagged `orphan:deferred_review` + `origin:arbiter` |
| **Discovery** | `ticket list --tag=orphan:deferred_review` at sprint start |
| **Addressed** | Code change made → close with `--reason="Addressed in sprint <id>: <summary>"` |
| **Obsolete** | Finding no longer relevant → close with `--reason="Obsolete: <reason>"` |
| **Escalated** | Finding is more severe than originally rated → re-open as a bug via `/dso:fix-bug` |

Orphan tasks appear in `ticket list` output by default (not closed, not deleted) so they remain visible across sessions.

## validate-issues.sh Exemption

`validate-issues.sh` health checks flag tickets with no `parent_id` as orphan warnings. Tickets tagged **both** `orphan:deferred_review` **and** `origin:arbiter` are exempt from this warning because they are intentionally parentless by design.

The exemption is scoped to the combination of both tags. A ticket with only `orphan:deferred_review` (missing `origin:arbiter`) is still flagged. See `plugins/dso/scripts/validate-issues.sh` `check_orphaned_tasks()`.

## Interim Consumer Migration Plan

As of epic `b575-ac1c-f720-4839` (2026-05-16), grep confirms no pre-existing callers in `plugins/dso/` produce `orphan:deferred_review`-tagged tickets. The DEFER ruling ticket creation behavior is being introduced in this epic (story `2d4c-763d-b543-4267`).

**For future callers that create orphan tasks:**
- Any script or skill that creates a ticket intended as a deferred-review orphan MUST add both `orphan:deferred_review` and `origin:arbiter` tags at creation time
- Scripts that create parentless tickets for other reasons (e.g., standalone bug reports) MUST NOT use these tags — they are reserved for arbiter-deferred findings
- Audit callers periodically with: `grep -r "orphan:deferred_review" plugins/ .claude/scripts/`
