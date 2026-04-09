# Contract: REPLAN_TRIGGER / REPLAN_RESOLVED Observability Signals

- Signal Name: REPLAN_TRIGGER / REPLAN_RESOLVED
- Status: accepted
- Scope: sprint self-healing loop → epic ticket comment audit trail (epic fbd4-2908)
- Date: 2026-04-04

## Purpose

This document defines the structured comment formats used by the `/dso:sprint` self-healing loop to record re-planning events on epic tickets for observability. The signals provide an audit trail showing when and why the sprint orchestrator triggered re-planning, and whether re-planning completed successfully.

Both signals are written as ticket comments via `.claude/scripts/dso ticket comment <epic-id> "<signal>"`. They are consumed by humans and tooling (e.g., resume-anchor scanners, session summaries) to understand sprint execution history.

---

## Signal Names

`REPLAN_TRIGGER` / `REPLAN_RESOLVED`

---

## Location

Both signals are written to **epic ticket comments** via `.claude/scripts/dso ticket comment <epic-id> "<signal>"`.

The epic is the top-level container for the sprint. Writing signals at the epic level means all re-planning events for the sprint are centralized in one place, regardless of which story triggered the event.

---

## REPLAN_TRIGGER

### Format

```
REPLAN_TRIGGER: <type> — <description>
```

### Field Definitions

| Field | Type | Description |
|---|---|---|
| `<type>` | enum | One of: `drift`, `failure`, `validation`, `review`. See Valid Types below. |
| `<description>` | free-text | Human-readable description of why re-planning was triggered and what action is being taken. |

### Valid Types

| Type | When to Use |
|---|---|
| `drift` | Codebase drift detected — files modified since task creation that affect one or more stories' tasks. Triggers re-invocation of implementation-plan for affected stories. Also emitted as `RELATES_TO_DRIFT` sub-variant when a `relates_to`-linked epic closes after implementation planning for a story. |
| `failure` | A story accumulated 2+ UNCERTAIN confidence signals on `STATUS:pass` tasks, indicating low confidence in the implementation. Triggers re-invocation of implementation-plan for the story. |
| `validation` | A story's done definition failed validation despite all tasks being closed. Triggers creation of TDD remediation tasks via implementation-plan. |
| `review` | A code review identified out-of-scope files — the implementation touched files outside the story's defined scope. Triggers re-invocation of implementation-plan to create tasks covering the review feedback. |

### Timing

`REPLAN_TRIGGER` is written to the epic **before** the re-planning action is taken. This ensures the audit trail exists even if re-planning fails or times out.

---

## REPLAN_RESOLVED

### Format

```
REPLAN_RESOLVED: <tier> — <description>
```

### Field Definitions

| Field | Type | Description |
|---|---|---|
| `<tier>` | enum | One of: `implementation-plan`, `brainstorm`. Identifies which re-planning tier resolved the trigger. |
| `<description>` | free-text | Human-readable description of what was resolved and how. |

### Valid Tiers

| Tier | When to Use |
|---|---|
| `implementation-plan` | Re-planning completed at the implementation-plan level — new tasks were created to address the trigger condition. This is the most common resolution path. |
| `brainstorm` | Re-planning required brainstorm-level re-examination — the story intent itself needed revision before tasks could be drafted. Used when `REPLAN_ESCALATE` was emitted by implementation-plan and brainstorm successfully revised the epic/story. |

### Timing

`REPLAN_RESOLVED` is written to the epic **after** successful re-planning completes. It is only written when re-planning finishes without emitting `REPLAN_ESCALATE` and without hitting the `sprint.max_replan_cycles` cap.

---

## Non-Interactive Mode

When `/dso:sprint` or `/dso:debug-everything` runs in non-interactive mode and a brainstorm escalation is needed (i.e., implementation-plan emits `REPLAN_ESCALATE: brainstorm`), the orchestrator cannot block for user confirmation.

In non-interactive mode, record the following instead of blocking:

```bash
.claude/scripts/dso ticket comment <epic-id> "INTERACTIVITY_DEFERRED: brainstorm — <reason>. Requires interactive session to proceed."
```

The `INTERACTIVITY_DEFERRED` comment replaces `REPLAN_RESOLVED` in this case — no resolved signal is written because the brainstorm escalation was not completed. The story remains blocked pending a follow-up interactive session.

**Note**: The resume-anchor scanner does NOT scan `INTERACTIVITY_DEFERRED` lines automatically. After a non-interactive session, manually run `.claude/scripts/dso ticket show <epic-id>` and inspect comments for `INTERACTIVITY_DEFERRED` entries to find items requiring follow-up.

---

## Example Payloads

### drift trigger

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_TRIGGER: drift — Files drifted: plugins/dso/hooks/pre-bash.sh, plugins/dso/hooks/post-bash.sh. Re-invoking implementation-plan for 2 affected stories."
```

### relates_to drift trigger

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_TRIGGER: drift — RELATES_TO_DRIFT: related epic epic-5678 closed after implementation planning for story story-9012. Re-invoking implementation-plan to re-evaluate task alignment."
```

### failure trigger

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_TRIGGER: failure — Story story-5678 had 2+ UNCERTAIN signals. Routing to implementation-plan."
```

### validation trigger

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_TRIGGER: validation — Story story-5678 validation failed with all tasks closed. Creating TDD remediation tasks."
```

### review trigger

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_TRIGGER: review — Out-of-scope files from review: plugins/dso/scripts/record-review.sh. Routing to implementation-plan for story story-5678." # shim-exempt: example file path in REPLAN_TRIGGER message text, not a command invocation
```

### implementation-plan resolution

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_RESOLVED: implementation-plan — Drift re-planning complete for 2 stories."
```

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_RESOLVED: implementation-plan — Story story-5678 re-planned after confidence failures."
```

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_RESOLVED: implementation-plan — Remediation tasks created for story story-5678."
```

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_RESOLVED: implementation-plan — Tasks created for out-of-scope review feedback on story story-5678."
```

### brainstorm resolution

```bash
.claude/scripts/dso ticket comment epic-1234 "REPLAN_RESOLVED: brainstorm — Story story-5678 re-examined and revised after implementation-plan could not satisfy success criteria."
```

### non-interactive deferral

```bash
.claude/scripts/dso ticket comment epic-1234 "INTERACTIVITY_DEFERRED: brainstorm — implementation-plan emitted REPLAN_ESCALATE for story story-5678. Story intent requires brainstorm-level re-examination. Requires interactive session to proceed."
```

---

### Canonical parsing prefix

Tooling that scans epic ticket comments for these signals MUST match against these canonical prefixes:

- `REPLAN_TRIGGER: ` — note the colon-space separator
- `REPLAN_RESOLVED: ` — note the colon-space separator
- `INTERACTIVITY_DEFERRED: brainstorm` — for non-interactive brainstorm deferrals

The `—` (em dash) separator between `<type>/<tier>` and `<description>` is decorative and MUST NOT be included in prefix matching — match only up to the end of the type/tier token.

---

## Relationship to REPLAN_ESCALATE

`REPLAN_TRIGGER` / `REPLAN_RESOLVED` are **observability signals** written to ticket comments. They are distinct from `REPLAN_ESCALATE` (defined in `replan-escalate-signal.md`), which is an **inter-skill signal** emitted as output text from the implementation-plan skill.

| Signal | Type | Written by | Consumed by |
|---|---|---|---|
| `REPLAN_TRIGGER` | Ticket comment | Sprint orchestrator | Humans, resume-anchor scanners |
| `REPLAN_RESOLVED` | Ticket comment | Sprint orchestrator | Humans, resume-anchor scanners |
| `REPLAN_ESCALATE` | Skill output text | implementation-plan SKILL.md | Sprint orchestrator parser |

`REPLAN_ESCALATE` causes the sprint orchestrator to emit `INTERACTIVITY_DEFERRED: brainstorm` (non-interactive) or invoke `/dso:brainstorm` interactively, which on success produces `REPLAN_RESOLVED: brainstorm`.

---

## Consumers

The following components write or read these signals:

| Component | Role | Notes |
|---|---|---|
| `plugins/dso/skills/sprint/SKILL.md` Phase 1 Step 6 | Emitter (drift) | Written before/after implementation-plan re-invocations for drifted files # shim-exempt: internal implementation path reference |
| `plugins/dso/skills/sprint/SKILL.md` Phase 5 Step 9 | Emitter (failure) | Written before/after implementation-plan re-invocation for 2+ UNCERTAIN stories # shim-exempt: internal implementation path reference |
| `plugins/dso/skills/sprint/SKILL.md` Phase 6 Step 2 | Emitter (validation) | Written before/after implementation-plan remediation task creation # shim-exempt: internal implementation path reference |
| `plugins/dso/skills/sprint/SKILL.md` Phase 7 Step 2 | Emitter (review) | Written before/after implementation-plan re-invocation for out-of-scope review files # shim-exempt: internal implementation path reference |
| Human operators | Consumer | Read epic ticket history to understand sprint re-planning events |
| Resume-anchor scanners | Consumer | Scan `CHECKPOINT` and `REPLAN_TRIGGER` lines to reconstruct sprint state |

---

## Versioning

This contract is versioned. Breaking changes (format changes, enum value changes, prefix changes) require updating all emitters and this document atomically in the same commit. Additive changes that do not affect the canonical parsing prefix are backward-compatible.

### Change Log

- **2026-04-08**: Additive — documents `RELATES_TO_DRIFT` sub-variant of the `drift` trigger type: emitted when a `relates_to`-linked epic closes after implementation planning, detected by `sprint-drift-check.sh`.
- **2026-04-04**: Initial version — defines REPLAN_TRIGGER/REPLAN_RESOLVED observability signal formats for the sprint self-healing loop. Covers all 4 trigger types (drift, failure, validation, review), both resolved tiers (implementation-plan, brainstorm), and INTERACTIVITY_DEFERRED handling for non-interactive mode.
