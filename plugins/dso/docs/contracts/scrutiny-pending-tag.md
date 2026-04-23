# Contract: scrutiny:pending Tag

- Status: accepted
- Scope: roadmap-scrutiny-gate (epic 02b2-c73d)
- Date: 2026-03-27

## Purpose

This document defines the contract for the `scrutiny:pending` tag on epic tickets. The tag signals that an epic was created via `/dso:roadmap` but skipped the built-in scrutiny pipeline (gap analysis, web research, scenario analysis, fidelity review). Downstream skills use this tag as an entry gate to block premature decomposition or implementation planning.

---

## Tag Name

`scrutiny:pending`

---

## Semantics

When the `scrutiny:pending` tag is present on an epic ticket, the epic has **NOT** been through the scrutiny pipeline. Downstream skills must halt at their entry gate and direct the practitioner to run `/dso:brainstorm` first, which runs full scrutiny and removes the need for the tag.

---

## Allowed Values

| State | Meaning |
|---|---|
| Present (tag exists on ticket) | Epic has not been scrutinized — downstream skills must block |
| Absent (tag not on ticket) | Epic is cleared for decomposition or implementation planning |

---

## Default-Deny Note

Missing tag is treated as **absent** (not pending). Only epics that are explicitly tagged with `scrutiny:pending` are blocked. Pre-existing epics created before this contract was introduced are **not** retroactively blocked.

---

## Writer

`/dso:roadmap` — writes the tag during the scrutiny decision step when the practitioner opts out of the scrutiny pipeline. (Implementation: story 02b2-c73d)

---

## Readers

| Skill | Gate Location | Action on Tag Present |
|---|---|---|
| `/dso:preplanning` | Entry gate | Halt and direct practitioner to run `/dso:brainstorm` on the epic |
| `/dso:implementation-plan` | Entry gate | Halt and direct practitioner to run `/dso:brainstorm` on the epic |

---

## Lifecycle

1. `/dso:roadmap` writes the tag on the epic ticket when the practitioner opts out of scrutiny in Phase 2.5.
2. The practitioner runs `/dso:brainstorm` on the epic, which executes the full scrutiny pipeline (gap analysis, web research, scenario analysis, fidelity review).
3. `/dso:brainstorm` removes the `scrutiny:pending` tag from the epic upon successful completion of scrutiny.
4. Downstream skills (`/dso:preplanning`, `/dso:implementation-plan`) proceed normally once the tag is absent.

---

## Failure Contract

If a downstream skill cannot determine tag presence (e.g., ticket read failure), it must treat the tag as **absent** and proceed normally. The gate is a guardrail, not a hard blocker on infrastructure failure.

## Related Contracts

- [Tag Policy](../ticket-system-v3-architecture.md#tag-policy) — meta-policy governing tag guards, writer taxonomy, and accepted limitations
