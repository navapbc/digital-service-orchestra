# Contract: interaction:deferred Tag

- Status: accepted
- Scope: cross-epic interaction halt mechanism (story 3c31-8050)
- Date: 2026-04-16

## Purpose

This document defines the contract for the `interaction:deferred` tag on epic tickets. The tag signals that an epic's cross-epic artifact overlap produced unresolved ambiguity or conflict signals during `/dso:brainstorm` Step 2.27. Downstream skills use this tag as an entry gate to block decomposition or implementation planning until the practitioner resolves or overrides the signals.

---

## Tag Name

`interaction:deferred`

---

## Semantics

When the `interaction:deferred` tag is present on an epic ticket, the epic has cross-epic interaction conflicts that have NOT been resolved by the practitioner. Downstream skills must halt at their entry gate and direct the practitioner to run `/dso:brainstorm` first, which presents resolution options and removes the tag when the conflict is addressed.

---

## Allowed Values

| State | Meaning |
|---|---|
| Present (tag exists on ticket) | Epic has unresolved cross-epic ambiguity or conflict signals — downstream skills must block |
| Absent (tag not on ticket) | Epic is cleared for decomposition or implementation planning |

---

## Default-Deny Note

Missing tag is treated as **absent** (not deferred). Only epics that are explicitly tagged with `interaction:deferred` are blocked. Pre-existing epics created before this contract was introduced are **not** retroactively blocked.

---

## Writer

`/dso:brainstorm` — writes the tag during Step 2.27 (Cross-Epic Interaction Signal Check) when cross-epic artifact overlap produces `severity="ambiguity"` or `severity="conflict"` signals and the practitioner has not yet resolved them.

Tag write command:
```bash
.claude/scripts/dso ticket tag <epic-id> interaction:deferred
```

Tag removal (on override):
```bash
.claude/scripts/dso ticket untag <epic-id> interaction:deferred
```

---

## Readers

| Skill | Gate Location | Action on Tag Present |
|---|---|---|
| `/dso:preplanning` | Interaction Conflict Gate (entry) | Halt and direct practitioner to run `/dso:brainstorm` on the epic |
| `/dso:implementation-plan` | Interaction Conflict Gate (entry) | Halt and direct practitioner to run `/dso:brainstorm` on the epic |
| `/dso:sprint` | Phase 3 Batch Preparation — Interaction Conflict Filter | Skip the tagged epic's tasks from the dispatch batch (no error; log and continue) |

---

## Lifecycle

1. `/dso:brainstorm` Step 2.27 detects cross-epic artifact overlap with `severity="ambiguity"` or `severity="conflict"`.
2. `/dso:brainstorm` writes the `interaction:deferred` tag on the epic ticket.
3. **Interactive path**: The practitioner is presented with resolution options (resolve, override, halt).
   - On **resolve**: The practitioner clarifies approach or scope; brainstorm re-enters Phase 1 and re-checks signals in Step 2.27.
   - On **override**: The tag is removed immediately and brainstorm proceeds to the scrutiny pipeline (Step 2.5).
   - On **halt**: The tag remains and the session ends. The practitioner must re-run `/dso:brainstorm` to address the conflict.
4. **Non-interactive path**: The tag is written and `INTERACTIVITY_DEFERRED` is logged. Brainstorm does not proceed to Step 2.5.
5. Downstream skills (`/dso:preplanning`, `/dso:implementation-plan`) halt when the tag is present.
6. `/dso:sprint` silently skips tasks from tagged epics in each batch.
7. The practitioner re-runs `/dso:brainstorm <epic-id>` interactively to resolve the signals and have the tag removed.

---

## Failure Contract

If a downstream skill cannot determine tag presence (e.g., ticket read failure), it must treat the tag as **absent** and proceed normally. The gate is a guardrail, not a hard blocker on infrastructure failure.

---

## Related Contracts

- `scrutiny:pending` tag (`docs/contracts/scrutiny-pending-tag.md`) — same gate pattern; blocks when epic has not been through the scrutiny pipeline
- [Tag Policy](../ticket-system-v3-architecture.md#tag-policy) — meta-policy governing tag guards, writer taxonomy, and accepted limitations
