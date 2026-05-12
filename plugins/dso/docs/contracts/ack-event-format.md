# Contract: ACK Event Format

> **FROZEN** — This contract is S1-frozen. The field set, types, and schema_version value below cannot change without re-opening this contract. Re-opening requires updating all consumers listed in `precondition-degradation-consumers.md`.

---

## Purpose

This document defines the frozen format for ACK events written by `preconditions-ack` (via `check-unacked-degradations.sh`) to record that a practitioner has explicitly acknowledged a graceful-degradation decision. ACK events are paired with `PRECONDITIONS` events that carry `data.degradation=true`.

---

## Signal Name

`ACK` (file suffix: `*-ACK.json`)

---

## Emitter

`${CLAUDE_PLUGIN_ROOT}/scripts/preconditions-ack` — writes one ACK file per acknowledgement session to `.tickets-tracker/<ticket_id>/<timestamp>-<uuid>-ACK.json`. # tickets-boundary-ok

---

## Consumer

`${CLAUDE_PLUGIN_ROOT}/scripts/check-unacked-degradations.sh` — the primary consumer. Additional consumers are enumerated in `precondition-degradation-consumers.md`.

---

## Frozen Field Set (schema_version=1)

All five fields are required in every ACK event. No optional fields exist at this schema version.

| Field | Type | Constraints | Description |
|---|---|---|---|
| `decision_ids` | array of strings | Non-empty; each element is a `decision_id` string | The decision IDs being acknowledged. Matches `data.decision_ids` from the corresponding PRECONDITIONS event. |
| `if_skipped` | string | Required; must be ≥ 10 characters; must not be empty | Human-readable rationale for accepting the degradation. Used by `check-unacked-degradations.sh` for 3-word-window rationale validation. |
| `timestamp` | string | ISO 8601 UTC; format `YYYY-MM-DDTHH:MM:SSZ` | When the acknowledgement was recorded. |
| `sampled_set` | array of strings or null | null for single-decision acks; exactly 3 elements for sample-ack mode | For sample-ack mode, contains the 3 decision_ids that were sampled from a larger set. null when acknowledging a single decision directly. |
| `schema_version` | integer | Frozen at `1` | Schema version identifier. Readers MUST reject ACK events where this field is absent or not equal to 1 (unknown future versions are not forward-compatible for ACK events). |

---

## decision_id Format

A `decision_id` takes one of the following forms:

- `sess:<session_id_short_hash>` — e.g., `sess:abc123def456`
- Opaque string — any non-empty string identifier

Consumers MUST NOT parse or assume internal structure from a `decision_id`. Treat it as an opaque key for matching against PRECONDITIONS event `data.decision_ids`.

---

## JSON Format Example

```json
{"decision_ids": ["sess:abc123def456"], "if_skipped": "implementation plan must be complete before sprint executes; verified no child tasks existed", "timestamp": "2026-05-11T14:30:00Z", "sampled_set": null, "schema_version": 1}
```

Sample-ack mode example (3-element `sampled_set`):

```json
{"decision_ids": ["sess:abc123def456", "sess:def456ghi789", "sess:ghi789jkl012", "sess:jkl012mno345", "sess:mno345pqr678"], "if_skipped": "batch of sprint pre-checks verified; preconditions met for all stories in this epic", "timestamp": "2026-05-11T15:00:00Z", "sampled_set": ["sess:abc123def456", "sess:ghi789jkl012", "sess:mno345pqr678"], "schema_version": 1}
```

---

### Canonical parsing prefix

Parsers MUST identify ACK events by file suffix (`*-ACK.json`) combined with `schema_version=1`. The `schema_version` field in the JSON object is authoritative for validation — readers MUST reject ACK events where `schema_version` is absent or not equal to `1`. Unlike PRECONDITIONS events, ACK events do not carry an `event_type` field; the file suffix is the sole discovery mechanism.

---

## Field-Level Constraints (Normative)

1. **`decision_ids`**: must be a JSON array with at least one element. Each element must be a non-empty string. An empty array is invalid.
2. **`if_skipped`**: must be a non-empty string with at least 10 characters. Whitespace-only strings are invalid. The field must be present even when `sampled_set` is non-null.
3. **`timestamp`**: must conform to `YYYY-MM-DDTHH:MM:SSZ` exactly. Fractional seconds and timezone offsets other than `Z` are not accepted at this schema version.
4. **`sampled_set`**: must be either JSON `null` or a JSON array of exactly 3 non-empty strings. Arrays of any other length are invalid. When non-null, each element must appear in `decision_ids`.
5. **`schema_version`**: must be the integer `1`. String `"1"` is invalid.

---

## Contract Freeze Notice

This contract is frozen at schema_version=1 as of the S1 milestone of epic 736d-b957. To introduce a new field or change a constraint:

1. Create a new schema_version (integer > 1).
2. Update this document with the new version's field table.
3. Update all consumers listed in `${CLAUDE_PLUGIN_ROOT}/docs/precondition-degradation-consumers.md`.
4. Announce the change in the epic that introduces it and reference this contract from that epic's spec.
