# Contract: APPROACH_DECISION Signal

- Signal Name: APPROACH_DECISION
- Status: accepted
- Scope: approach-decision-maker → implementation-plan resolution loop (epic dso-gkct)
- Date: 2026-04-05

## Purpose

This document defines the shared output interface for the `APPROACH_DECISION` signal emitted by the `dso:approach-decision-maker` agent when evaluating competing implementation proposals for a story or task. The `/dso:implementation-plan` skill consumes this signal in its resolution loop to determine which proposal to adopt or whether a counter-proposal is required.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure the emitter and parser stay in sync.

---

## Signal Name

`APPROACH_DECISION`

---

## Emitter

`agents/approach-decision-maker.md` — Named agent dispatched by `/dso:implementation-plan` during proposal evaluation # shim-exempt: internal implementation path reference

The emitter receives a set of implementation proposals (each with a description and done definitions), the story success criteria, and current codebase context. It evaluates the proposals using ADR-style reasoning and outputs one of two structured JSON payloads: a **selection** (choosing an existing proposal) or a **counter-proposal** (defining a new approach when no existing proposal is satisfactory). The emitter MUST output exactly one JSON payload per invocation — no additional commentary before or after the JSON block.

---

## Parser

`skills/implementation-plan/SKILL.md` — Implementation Plan skill resolution loop (Story 4acd-215a) # shim-exempt: internal implementation path reference

The parser reads the approach-decision-maker agent output, parses the JSON payload, and routes accordingly: if `mode` is `selection`, the parser adopts the referenced proposal; if `mode` is `counter_proposal`, the parser incorporates the counter-proposal approach into task decomposition. The parser MUST validate the `mode` field before acting.

---

## Output Modes

The emitter produces one of two output modes, distinguished by the `mode` field.

### Mode A: Selection

Used when one of the submitted proposals satisfactorily covers all success criteria and is preferable to the others. The emitter selects the proposal by index and provides ADR-style rationale.

**Fields:**

| Field | Type | Required | Description |
|---|---|---|---|
| `mode` | string (enum) | yes | Always `"selection"` for this mode. |
| `selected_proposal_index` | integer | yes | Zero-based index of the chosen proposal from the input list. |
| `context` | string | yes | ADR Context — description of the forces at play: constraints, trade-offs, and the decision environment considered. Must not be empty. |
| `decision` | string | yes | ADR Decision — statement of the choice made and the core reason it was chosen over alternatives. Must not be empty. |
| `consequences` | string | yes | ADR Consequences — expected outcomes of adopting this proposal: benefits, risks, and any follow-up actions needed. Must not be empty. |
| `rationale_summary` | string | yes | One-sentence summary suitable for a commit message or ticket comment. Must not be empty. |

### Mode B: Counter-Proposal

Used when no submitted proposal satisfactorily covers all success criteria. The emitter defines a new approach whose done definitions collectively satisfy all success criteria.

**Fields:**

| Field | Type | Required | Description |
|---|---|---|---|
| `mode` | string (enum) | yes | Always `"counter_proposal"` for this mode. |
| `proposal_title` | string | yes | Short descriptive title for the counter-proposal (≤ 100 characters). |
| `approach` | string | yes | Full description of the proposed implementation approach. Must be concrete enough to derive tasks from. Must not be empty. |
| `done_definitions` | array of strings | yes | Ordered list of done definitions that collectively satisfy all story success criteria. Must be non-empty. Each entry must be a testable, atomic statement. |
| `context` | string | yes | ADR Context — same semantics as Mode A. Must not be empty. |
| `decision` | string | yes | ADR Decision — explains why no existing proposal was adequate and why this counter-proposal was constructed instead. Must not be empty. |
| `consequences` | string | yes | ADR Consequences — same semantics as Mode A. Must not be empty. |
| `rationale_summary` | string | yes | One-sentence summary suitable for a commit message or ticket comment. Must not be empty. |

---

## Signal Format

The emitter outputs a single JSON object wrapped in a fenced code block:

```
APPROACH_DECISION:
```json
{ ... }
```
```

The parser MUST scan for the `APPROACH_DECISION:` prefix line, then read the JSON block that follows on the next line. The JSON payload is the complete decision record. No fields outside the JSON block are authoritative.

### Canonical parsing prefix

The parser MUST match against:

```
APPROACH_DECISION:
```

(The prefix appears on its own line immediately before the opening fence of the JSON block.) Any output section starting with this prefix is a candidate signal. The parser extracts the JSON block between the opening ` ```json ` and closing ` ``` ` fences.

---

## Example Payloads

### Example A: Selection

```
APPROACH_DECISION:
```json
{
  "mode": "selection",
  "selected_proposal_index": 1,
  "context": "Two proposals were evaluated: one using an in-process cache and one using a Redis-backed store. The story requires cache invalidation on write, low latency reads, and horizontal scalability. The service already depends on Redis for session storage.",
  "decision": "Adopt proposal 1 (Redis-backed cache). The existing Redis dependency eliminates infrastructure overhead, and Redis pub/sub satisfies the invalidation-on-write requirement cleanly. The in-process cache (proposal 0) cannot support invalidation across multiple service replicas.",
  "consequences": "Proposal 1 adds a Redis round-trip per cache read (~1ms overhead) but enables safe horizontal scaling. The team must ensure Redis availability is monitored. No new dependencies are introduced.",
  "rationale_summary": "Select Redis-backed cache (proposal 1): satisfies invalidation-on-write and horizontal scalability using existing Redis infrastructure."
}
```
```

### Example B: Counter-Proposal

```
APPROACH_DECISION:
```json
{
  "mode": "counter_proposal",
  "proposal_title": "Event-sourced audit log with async projection",
  "approach": "Replace the proposed synchronous write-through audit model with an event-sourced log. Each state change emits an immutable domain event to an append-only store. A background projection worker reads the event stream and materializes the audit table. This decouples writes from audit logging latency and satisfies the tamper-evidence requirement via immutable event records.",
  "done_definitions": [
    "Every state-changing API call appends a domain event to the immutable event store within the same transaction.",
    "The audit projection worker processes events within 5 seconds of emission under normal load.",
    "Audit records cannot be deleted or modified after creation (enforced at the store layer).",
    "The audit log UI reflects the projected state within 10 seconds of the originating write."
  ],
  "context": "Two proposals were submitted: a synchronous write-through audit log and a trigger-based approach. Both introduce write-path latency that violates the p99 < 50ms SLO for state-changing endpoints. The tamper-evidence requirement also rules out trigger-based approaches, which can be disabled by schema changes.",
  "decision": "Neither submitted proposal is acceptable: proposal 0 adds synchronous latency exceeding the SLO, and proposal 1 relies on database triggers that are bypassable. A counter-proposal using an event-sourced append-only log satisfies tamper-evidence without adding write-path latency.",
  "consequences": "The counter-proposal introduces an async projection worker as a new service component. Audit reads will reflect events with up to 10s of lag. The team must operate and monitor the projection worker. Operational complexity increases, but write-path latency and tamper-evidence requirements are both satisfied.",
  "rationale_summary": "Counter-proposal: event-sourced audit log with async projection — satisfies tamper-evidence and write latency SLO where submitted proposals could not."
}
```
```

---

## Failure Contract

If the approach-decision-maker output is:

- absent (agent timed out, returned non-zero exit, or produced no output),
- malformed (missing `APPROACH_DECISION:` prefix, invalid JSON, missing required fields),
- contains an unrecognized `mode` value (not `selection` or `counter_proposal`),
- or contains a `selection` mode payload with `selected_proposal_index` out of bounds for the input proposal list,

then the parser MUST treat the decision as failed and surface the failure to the user for manual resolution. Autonomous fallback to any proposal is prohibited — an incorrect automated selection risks task decomposition based on wrong assumptions.

The parser must log a warning when the signal is malformed so that silent degradation is detectable in debug output.

---

## Consumers

The following components emit or consume this signal:

| Component | Role | Notes |
|---|---|---|
| `agents/approach-decision-maker.md` | Emitter | Named agent dispatched during implementation-plan proposal evaluation (Story a1f3-db49) # shim-exempt: internal implementation path reference |
| `skills/implementation-plan/SKILL.md` resolution loop | Parser | Reads decision to adopt a proposal or incorporate counter-proposal into task decomposition (Story 4acd-215a) # shim-exempt: internal implementation path reference |

All implementors must read this contract before writing the emitter agent or parser logic. Changes to the signal format require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (format changes, field removal, prefix changes, mode value changes) require updating both all emitters and parsers and this document atomically in the same commit. Additive changes that do not affect the canonical parsing prefix or required fields are backward-compatible.

### Change Log

- **2026-04-05**: Initial version — defines APPROACH_DECISION signal for approach-decision-maker agent → implementation-plan resolution loop. Establishes two output modes (selection with ADR rationale, counter-proposal with done definitions), canonical parsing prefix, failure contract, and example payloads.
