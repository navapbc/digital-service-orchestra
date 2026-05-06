# Contract: inference-envelope

- Signal Name: INFERENCE_CHALLENGE / INFERENCE_SKIP
- Status: accepted
- Scope: inference validation workflow — challenge and skip signals for inference decisions
- Date: 2026-05-05

## Purpose

Defines the wire format for inference validation signals emitted by the inference validation layer. Covers two signal types: `INFERENCE_CHALLENGE` (flags a decision for user confirmation) and `INFERENCE_SKIP` (records that a check was bypassed due to prior confirmation). This contract must be agreed upon before emitter or parser is implemented.

## Signal Name

`INFERENCE_CHALLENGE` / `INFERENCE_SKIP`

---

## Status

accepted

---

## Format

### INFERENCE_CHALLENGE signal

Emitted when an inference decision is flagged for user confirmation.

Fields:

| Field | Type | Description |
|-------|------|-------------|
| `decision_id` | string | Decision identifier in `<session_id>:<content_hash>` format (see `decision-id-format.md`) |
| `challenge_type` | enum | Type of challenge: `unsupported_assumption`, `contradicted_evidence`, `scope_drift`, `hallucination_risk` |
| `evidence_against_inference` | string | Human-readable description of evidence that contradicts or fails to support the inference |
| `user_confirmation_required` | bool | Always `true` for `INFERENCE_CHALLENGE` — the inference must not proceed without explicit user approval |

Example:

```
INFERENCE_CHALLENGE: decision_id=pv-session-1746500000000:a3f70b2c14e8d931 challenge_type=unsupported_assumption evidence_against_inference="No prior session data found; warm cache assumption is unverified" user_confirmation_required=true
```

### INFERENCE_SKIP signal

Emitted when an inference check is bypassed due to prior confirmation or known-safe conditions.

Fields:

| Field | Type | Description |
|-------|------|-------------|
| `reason` | string | Human-readable explanation for why the inference check was skipped |
| `hash_bucket` | string | Content hash prefix (first 8 hex chars of content_hash) used for deduplication lookup |

Example:

```
INFERENCE_SKIP: reason="decision previously confirmed in this session" hash_bucket=a3f70b2c
```

---

## Emitter

The inference validation layer in the fix-bug and sprint skills emits `INFERENCE_CHALLENGE` when an inference is detected that lacks supporting evidence. It emits `INFERENCE_SKIP` when a prior confirmation is found in the session's inference ledger.

---

## Parser

The orchestrator (fix-bug Phase B, sprint Phase H) parses both signal types. On `INFERENCE_CHALLENGE`, the orchestrator pauses and presents the challenge to the user before proceeding. On `INFERENCE_SKIP`, the orchestrator logs the skip and continues without interruption.

### Canonical parsing prefix

The parser MUST match lines beginning with `INFERENCE_CHALLENGE:` or `INFERENCE_SKIP:` (exact prefix, case-sensitive). Each signal is emitted as a single line. Parsers MUST extract key=value fields by splitting on whitespace after the prefix token and parsing `key=value` pairs. The `evidence_against_inference` and `reason` fields may contain quoted strings; parsers MUST handle quoted values.

---

## Consumers

| Component | Role |
|-----------|------|
| fix-bug SKILL.md Phase B | Parser — halts on INFERENCE_CHALLENGE |
| sprint SKILL.md Phase H | Parser — halts on INFERENCE_CHALLENGE |
| Inference envelope emitter | Emits both signal types |
