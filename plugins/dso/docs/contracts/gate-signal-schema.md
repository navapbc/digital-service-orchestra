# Contract: Gate Signal Schema

- Signal Name: GATE_SIGNAL
- Status: accepted
- Scope: fix-bug classification gates (epic 4b97-bd9d)
- Date: 2026-03-28

## Purpose

This document defines the shared output interface for all classification gates (1a, 1b, 2a, 2b, 2c, 2d) used in the `/dso:fix-bug` workflow. Each gate emits a JSON object conforming to this schema. The escalation router (Story a2f0-9641) consumes these signals to determine routing decisions across the classification pipeline.

This contract must be agreed upon before any gate is implemented to prevent implicit assumptions and ensure emitters and the parser stay in sync.

---

## Signal Name

`GATE_SIGNAL`

---

## Emitter

Each gate script conforming to this contract:

- `plugins/dso/scripts/gate-1a.sh` (or inline in `plugins/dso/skills/fix-bug/SKILL.md`) — Gate 1a (Story 6775-b635) # shim-exempt: internal implementation path reference
- `plugins/dso/scripts/gate-1b.sh` (or inline) — Gate 1b (Story 5260-e9ba) # shim-exempt: internal implementation path reference
- `plugins/dso/scripts/gate-2a.sh` (or inline) — Gate 2a (Story e965-7cb7) # shim-exempt: internal implementation path reference
- `plugins/dso/scripts/gate-2b.sh` (or inline) — Gate 2b (Story 2c25-5751) # shim-exempt: internal implementation path reference
- `plugins/dso/scripts/gate-2c.sh` (or inline) — Gate 2c (Story e7a0-b991) # shim-exempt: internal implementation path reference
- `plugins/dso/scripts/gate-2d.sh` (or inline) — Gate 2d (Story e965-7cb7) # shim-exempt: internal implementation path reference

Each emitter evaluates its gate condition, then prints a single JSON object to stdout and exits 0 on success or non-zero on failure.

---

## Parser

`plugins/dso/skills/fix-bug/SKILL.md` — Escalation router (Story a2f0-9641)

The parser invokes each gate emitter in sequence, reads its stdout, and uses `triggered` and `signal_type` to determine classification routing and escalation path.

---

## Schema

The emitter outputs a single JSON object on stdout. All fields are required.

| Field | Type | Description |
|---|---|---|
| `gate_id` | string | Gate identifier, e.g. `"1a"`, `"1b"`, `"2a"`, `"2b"`, `"2c"`, `"2d"` |
| `triggered` | boolean | `true` if the gate condition fired and this gate's signal should influence routing; `false` otherwise |
| `signal_type` | string (enum) | Role of this gate in the classification pipeline. One of: `"primary"` (drives top-level routing decision), `"modifier"` (adjusts or refines a primary signal) |
| `evidence` | string | Human-readable summary of the evidence that caused `triggered` to be `true`, or an explanation of why the gate did not fire when `triggered` is `false`. Must not be empty. |
| `confidence` | string (enum) | Confidence level of the gate's determination. One of: `"high"`, `"medium"`, `"low"` |

### `signal_type` Enum Values

| Value | Meaning |
|---|---|
| `"primary"` | This gate is a top-level routing signal. When triggered, it drives the main classification branch selection. |
| `"modifier"` | This gate refines or adjusts the output of a primary gate. Modifier gates are evaluated after primary gates and may narrow, escalate, or annotate the routing decision. |

### `confidence` Enum Values

| Value | Meaning |
|---|---|
| `"high"` | Gate condition matched unambiguously; routing should rely on this signal without hedging |
| `"medium"` | Gate condition matched with moderate certainty; additional context may be warranted |
| `"low"` | Gate condition matched weakly or heuristically; downstream router should treat as advisory only |

---

## Example

### Gate fired (triggered: true)

```json
{
  "gate_id": "1a",
  "triggered": true,
  "signal_type": "primary",
  "evidence": "Stack trace present in bug description with 3 distinct frame references; import error pattern matched at line 42",
  "confidence": "high"
}
```

### Gate did not fire (triggered: false)

```json
{
  "gate_id": "2b",
  "triggered": false,
  "signal_type": "modifier",
  "evidence": "No regression indicators found; changed files show no overlap with previously fixed paths in git history",
  "confidence": "high"
}
```

### Canonical parsing prefix

The parser MUST match against:

- `GATE_SIGNAL` — this contract defines a JSON stdout interface. The parser reads the full JSON object from each gate emitter's stdout and inspects the `triggered`, `signal_type`, and `confidence` fields. No line-prefix matching applies; the parser must deserialize the JSON object to determine routing.

---

## Exit Code Semantics

| Exit code | Meaning |
|---|---|
| `0` | Success — stdout contains valid JSON conforming to this schema |
| non-zero | Failure — stdout may be absent, partial, or malformed |

---

## Failure Contract

If a gate emitter:

- exits non-zero,
- times out (exit code 144 from `test-batched.sh` or SIGURG),
- or outputs malformed JSON (not parseable or missing required fields),

then the parser **must** treat the gate as non-triggered (`triggered: false`) with `confidence: "low"` and continue routing without it. A failed gate must not block the fix-bug workflow.

The parser must log a warning when a gate fails so that silent degradation is detectable in debug output.

---

## Consumers

The following stories must emit output conforming to this schema:

| Story | Gate | Signal Type | Notes |
|---|---|---|---|
| 6775-b635 | 1a | primary | Intent search — pre-investigation |
| 5260-e9ba | 1b | primary | Feature-request language check — pre-investigation |
| e965-7cb7 | 2a, 2d | primary | Reversal check (2a) + dependency check (2d) — post-investigation |
| e7a0-b991 | 2c | primary | Test regression analysis — post-investigation |
| 2c25-5751 | 2b | modifier | Blast radius annotation — post-investigation, never a primary signal |

All gate implementors must read this contract before writing their emitter. Changes to this schema require updating all conforming emitters and this document atomically in the same commit.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, enum value removal) require updating both all emitters and this document atomically in the same commit. Additive changes (new optional fields) are backward-compatible for parsers that ignore unknown keys and do not require a version bump.

### Change Log

- **2026-03-28**: Initial version — defines shared schema for gates 1a, 1b, 2a, 2b, 2c, 2d (epic 4b97-bd9d).
