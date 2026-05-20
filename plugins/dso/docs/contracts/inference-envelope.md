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

Emitted as a JSON object included in the emitting sub-agent's structured report (not as a free-standing log line). Fields:

| Field | Type | Description |
|-------|------|-------------|
| `output_type` | string | Discriminator. MUST be the literal string `"INFERENCE_CHALLENGE"`. |
| `decision_id` | string | Decision identifier in `<session_id>:<content_hash>` format (see `decision-id-format.md`) |
| `challenge_type` | enum | Type of challenge: `unsupported_assumption`, `contradicted_evidence`, `scope_drift`, `hallucination_risk`, `inference_without_explicit_sourcing`. Each emitting agent typically uses one canonical value reflecting its detection mode (e.g., `red-team-reviewer` always uses `inference_without_explicit_sourcing`). |
| `evidence_against_inference` | string | Human-readable description of evidence that contradicts or fails to support the inference |
| `user_confirmation_required` | bool | Always `true` for `INFERENCE_CHALLENGE` — the inference must not proceed without explicit user approval |

Example:

```json
{
  "output_type": "INFERENCE_CHALLENGE",
  "decision_id": "pv-session-1746500000000:a3f70b2c14e8d931",
  "challenge_type": "unsupported_assumption",
  "evidence_against_inference": "No prior session data found; warm cache assumption is unverified",
  "user_confirmation_required": true
}
```

### INFERENCE_SKIP signal

Emitted when an inference check is bypassed due to prior confirmation or known-safe conditions.

Emitted as a JSON object included in the emitting sub-agent's structured report. Fields:

| Field | Type | Description |
|-------|------|-------------|
| `output_type` | string | Discriminator. MUST be the literal string `"INFERENCE_SKIP"`. |
| `decision_id` | string \| null | Decision identifier in `<session_id>:<content_hash>` format, or `null` when the skip is not tied to a specific decision (e.g., probabilistic-bucket skip during sampling). |
| `reason` | string | Human-readable explanation or short code (e.g., `"sampling"`, `"decision previously confirmed in this session"`) describing why the inference check was skipped. |
| `hash_bucket` | string | Content hash prefix (last 8 hex chars of SHA-256(decision_id)) used for deduplication lookup. |

Example:

```json
{
  "output_type": "INFERENCE_SKIP",
  "decision_id": "pv-session-1746500000000:a3f70b2c14e8d931",
  "reason": "decision previously confirmed in this session",
  "hash_bucket": "a3f70b2c"
}
```

---

## Emitter

The `red-team-reviewer` sub-agent is the only emitter today. It emits `INFERENCE_CHALLENGE` when a decision is sampled into the always-challenge tier (per the `affects_fields` rule in `red-team-reviewer.md`) or the probabilistic-challenge bucket; otherwise it emits `INFERENCE_SKIP`. Future skills (fix-bug, sprint) are designed to consume these signals via the parser described below; no skill currently emits them.

---

## Parser

Parsers consuming this signal MUST read the emitting sub-agent's structured report and match on `output_type == "INFERENCE_CHALLENGE"` or `"INFERENCE_SKIP"`. No general orchestrator-level parser exists today; signals are recorded in the sub-agent report and surfaced to the user via the orchestrator's report-handling layer. When a parser is wired into a skill, it MUST treat absence of the `output_type` discriminator as a malformed envelope and skip the record.

### Canonical parsing prefix

The canonical discriminator is the `output_type` field of each JSON envelope (one of `INFERENCE_CHALLENGE` or `INFERENCE_SKIP`, exact-match, case-sensitive). Parsers MUST decode the JSON object first and then dispatch on `output_type` — they MUST NOT pattern-match on a textual prefix (the old key=value wire format documented earlier versions of this contract has been retired). When a payload is read from the ticket-comment side-channel (see below), strip the literal `INFERENCE_CHALLENGE: ` text prefix from the comment body before JSON-decoding.

### Side-channel: ticket-comment emission

In addition to the primary structured-report emission, `red-team-reviewer.md` writes the same JSON payload as a ticket comment via the ticket CLI when inference-challenge mode triggers and the ticket CLI is available. The comment body is the literal prefix `INFERENCE_CHALLENGE: ` followed by the same JSON object documented in the INFERENCE_CHALLENGE section above. This is a side effect for forensic traceability — the orchestrator's primary consumption path remains the structured report; ticket-comment readers may parse the comment body by stripping the `INFERENCE_CHALLENGE: ` prefix and JSON-decoding the remainder.

---

## Consumers

| Component | Role |
|-----------|------|
| `red-team-reviewer` agent | Emits both signal types as JSON objects in its structured report |
| Future orchestrator parser (planned) | Will halt on INFERENCE_CHALLENGE; no automated consumer exists yet |
