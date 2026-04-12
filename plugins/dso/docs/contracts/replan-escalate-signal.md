# Contract: REPLAN_ESCALATE Signal

- Signal Name: REPLAN_ESCALATE
- Status: accepted
- Scope: implementation-plan → sprint escalation path (epic ca76-bb4e)
- Date: 2026-04-04

## Purpose

This document defines the shared output interface for the `REPLAN_ESCALATE` signal emitted by `/dso:implementation-plan` when task decomposition cannot satisfy all success criteria given the current codebase state. The `/dso:sprint` orchestrator consumes this signal to route the story to brainstorm-level re-examination rather than attempting implementation.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure the emitter and parser stay in sync.

---

## Signal Name

`REPLAN_ESCALATE`

---

## Emitter

`skills/implementation-plan/SKILL.md` — Implementation Plan skill # shim-exempt: internal implementation path reference

The emitter evaluates ambiguity and contradiction conditions during the ambiguity scan phase of task drafting, then prints the canonical signal string as a standalone output line and **stops all task decomposition immediately**. After emitting `REPLAN_ESCALATE`, the implementation-plan skill MUST halt and return the signal as its final output — no tasks are emitted, no further decomposition steps are executed.

---

## Parser

`skills/sprint/SKILL.md` — Sprint orchestrator (routing story 9d3e-957d) # shim-exempt: internal implementation path reference

The parser reads the output of the implementation-plan invocation, scans for the canonical signal prefix, and routes accordingly. When the signal is detected, the sprint orchestrator invokes `/dso:brainstorm` on the story rather than proceeding to implementation batches.

---

## Signal Format

The emitter outputs the signal as a single standalone line:

```
REPLAN_ESCALATE: brainstorm EXPLANATION:<explanation text>
```

### Field definitions

| Field | Type | Description |
|---|---|---|
| `brainstorm` | literal string | Escalation target. Always the literal value `brainstorm`, indicating the orchestrator should invoke `/dso:brainstorm` on the story. |
| `EXPLANATION:<text>` | string | Free-text human-readable explanation of why success criteria cannot be satisfied. The `EXPLANATION:` prefix is mandatory. `<text>` must not be empty. |

### Canonical parsing prefix

The canonical signal string the parser MUST match against is:

```
REPLAN_ESCALATE: brainstorm EXPLANATION:
```

Parsers must treat the colon-space prefix (`REPLAN_ESCALATE: `) and the `EXPLANATION:` field label (with colon, no space before the text) as fixed literals. Any line matching this prefix is a valid signal, regardless of the content following `EXPLANATION:`.

---

## Conditions for Emission

All of the following criteria must be evaluated during the ambiguity scan. The signal should be emitted if **any one** of these conditions is true AND the model has high confidence the intent itself requires brainstorm-level re-examination:

1. The ambiguity scan determines success criteria are actively contradicted by the current codebase state — not merely unclear (unclear criteria → `STATUS:blocked`).
2. The success criteria are internally contradictory (mutually exclusive with each other).
3. Task drafting cannot satisfy all success criteria simultaneously given the current codebase state, regardless of implementation approach.

The model must have **high confidence** that the story intent requires brainstorm-level re-examination. Uncertainty about implementation approach alone is insufficient to emit this signal.

---

## Distinction from STATUS:blocked

| Condition | Signal |
|---|---|
| Success criteria are unclear or ambiguous — the user can answer questions to unblock | `STATUS:blocked` |
| Success criteria are actively contradicted, internally contradictory, or unsatisfiable — the story intent itself needs brainstorm-level re-evaluation | `REPLAN_ESCALATE` |

`STATUS:blocked` pauses execution until the user provides clarifying input. `REPLAN_ESCALATE` is a terminal signal that stops task decomposition entirely and routes the story back to brainstorm.

---

## Terminal Signal Behavior

`REPLAN_ESCALATE` is a **terminal signal**. When emitted:

1. The implementation-plan skill MUST stop all task decomposition immediately.
2. No tasks are created, no subtasks are emitted.
3. The signal line is returned as the final output of the implementation-plan invocation.
4. The sprint orchestrator MUST NOT proceed to implementation batches for this story.

There is no partial output: either the signal is emitted (terminal halt) or normal task decomposition proceeds (signal absent).

---

## Example

```
REPLAN_ESCALATE: brainstorm EXPLANATION:The story requires both removing the legacy auth module and preserving backward-compatible token validation, but these are mutually exclusive given the current auth service architecture. The story intent needs re-examination before tasks can be drafted.
```

---

## Failure Contract

If the signal is:

- malformed (present but missing the `EXPLANATION:` field or empty explanation text),
- absent when it should have fired (the emitter timed out or returned non-zero exit),
- or unparseable (output does not contain the canonical prefix),

then the parser **must** treat it as `STATUS:blocked` and continue normally (do not halt the sprint; surface the story as blocked for user input).

The parser must log a warning when the signal is malformed so that silent degradation is detectable in debug output.

---

## Consumers

The following stories implement or consume this signal:

| Story | Role | Notes |
|---|---|---|
| ca76-bb4e | Emitter parent | Story defining REPLAN_ESCALATE emission in implementation-plan |
| 9d3e-957d | Parser | Sprint orchestrator routing for REPLAN_ESCALATE |
| bd1a-14a3 | Emitter implementor | Implements signal emission in implementation-plan SKILL.md |
| 43d6-4603 | Parser implementor | Implements signal parsing in sprint SKILL.md |

All implementors must read this contract before writing their emitter or parser. Changes to the signal format require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (format changes, field removal, prefix changes) require updating both all emitters and parsers and this document atomically in the same commit. Additive changes that do not affect the canonical parsing prefix are backward-compatible.

### Change Log

- **2026-04-04**: Initial version — defines REPLAN_ESCALATE signal for implementation-plan → sprint escalation path (epic ca76-bb4e). Adds AC7 (canonical parsing prefix) and AC8 (terminal signal behavior) per gap analysis.
