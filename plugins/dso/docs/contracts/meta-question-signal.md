# Contract: meta-question-signal

- Signal Name: META_QUESTION
- Status: accepted
- Scope: inference validation workflow — signals when an inference depends on a question that must be answered before investigation proceeds
- Date: 2026-05-05

## Purpose

Defines the `META_QUESTION` signal emitted when an inference or investigation depends on a foundational question that must be answered before proceeding. Distinguishes from `REPLAN_ESCALATE`: a meta-question requests clarification within the current plan; it does not signal that the plan must be redesigned. This contract must be agreed upon before any emitter or parser is implemented.

## Signal Name

`META_QUESTION`

---

## Status

accepted

---

## Format

```
META_QUESTION: <question_text> blocking_for=<blocking_context>
```

Fields:

| Field | Type | Description |
|-------|------|-------------|
| `question_text` | string | The meta-question that must be answered before the inference or investigation can proceed |
| `blocking_for` | string | The step, phase, or inference decision that is blocked until this question is answered |

Example:

```
META_QUESTION: "Is the cache invalidation assumption based on observed behavior or documentation?" blocking_for=inference:cache_warm_assumption
```

### blocking_for field

The `blocking_for` field identifies what is blocked. It takes the form `<context_type>:<identifier>` where:

- `inference:<label>` — blocks a specific inference from proceeding
- `phase:<phase_id>` — blocks a skill phase from proceeding
- `investigation:<step_id>` — blocks an investigation step

The orchestrator must not proceed past the blocked item until the META_QUESTION is resolved by user input.

---

## Emitter

The bot-psychologist agent and intent-search agent emit `META_QUESTION` when they detect that proceeding without answering a foundational question would produce an unreliable inference. The signal is emitted before any investigation output that depends on the unanswered question.

---

## Parser

The fix-bug and sprint orchestrators parse `META_QUESTION` signals by scanning sub-agent output for lines beginning with `META_QUESTION:`.

### Canonical parsing prefix

The parser MUST match lines beginning with `META_QUESTION:` (exact prefix, case-sensitive). The remainder of the line contains the question text followed by `blocking_for=<value>`. Parsers MUST extract `blocking_for` by splitting on `blocking_for=` and taking the remainder. The question text ends at the last occurrence of ` blocking_for=` on the line.

 On detection, the orchestrator:

1. Presents the question to the user.
2. Waits for an explicit answer.
3. Passes the answer back to the sub-agent or re-invokes the relevant phase with the answer in context.

**Important**: Do NOT emit `REPLAN_ESCALATE` in response to a `META_QUESTION`. A meta-question is a request for clarification, not a signal that the plan needs to be redesigned. Use `REPLAN_ESCALATE` only when the plan itself is fundamentally wrong, not when a single clarifying question would unblock progress.

---

## Consumers

| Component | Role |
|-----------|------|
| bot-psychologist agent | Emitter — emits when investigation premise is uncertain |
| intent-search agent | Emitter — emits when intent is ambiguous before inference |
| fix-bug SKILL.md Phase B | Parser — halts and presents to user |
| sprint SKILL.md Phase H | Parser — halts and presents to user |
