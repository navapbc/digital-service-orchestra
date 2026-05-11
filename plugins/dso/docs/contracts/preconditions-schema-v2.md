# Contract: Preconditions Schema v2

## Purpose

This document defines the `PRECONDITIONS_EVENT` schema emitted by `_write_preconditions()` in `ticket-lib.sh` and read by `_read_latest_preconditions()`. It codifies the `schema_version` evolution policy, the `manifest_depth` field-set discriminator, and the forward-compatibility contract for unknown schema versions.

This contract governs how the preconditions writer derives `schema_version` from the `tier` parameter, and how readers handle schema versions beyond the known range without rejecting events.

---

## Signal Name

`PRECONDITIONS_EVENT`

---

## Emitter

`preconditions-depth-classifier.sh` (via `_write_preconditions()` in `ticket-lib.sh`)

The emitter derives `schema_version` and `manifest_depth` from the `tier` argument using the mapping table in the `manifest_depth Field-Set Discriminator` section below. The emitter writes a JSON object to `.tickets-tracker/<ticket_id>/<timestamp>-<uuid>-PRECONDITIONS.json`. # tickets-boundary-ok

---

## Parser

`_read_latest_preconditions()` in `ticket-lib.sh`; stage-boundary validators (Stories 2 and 4 of epic 736d-b957)

The parser scans all `*-PRECONDITIONS.json` files for a ticket, filters by `gate_name` + `session_id`, and returns the lexicographically latest file (LWW). When `schema_version` is unknown (> 2), the parser logs a warning to stderr and falls back to minimal-tier interpretation.

---

## schema_version Evolution Policy

Schema versions are monotonically increasing integers starting at 1.

- **schema_version=1**: minimal-tier fields only. Emitted for `tier=minimal`.
- **schema_version=2**: standard/deep-tier fields added (`manifest_depth`, extended `gate_verdicts`). Emitted for `tier=standard` or `tier=deep`.
- **schema_version > 2**: reserved for future use. Readers MUST NOT reject events with unknown versions; they MUST fall back to minimal-tier interpretation and emit a deduplicated warning to stderr.

The `schema_version` field is written by the emitter at write time. Readers must never infer it from file name or path.

---

## manifest_depth Field-Set Discriminator

The `manifest_depth` field discriminates which fields are populated in the event JSON:

| manifest_depth | schema_version | tier parameter | Additional fields |
|---|---|---|---|
| `minimal` | 1 | `minimal` | None beyond base fields |
| `standard` | 2 | `standard` | Reserved for Stories 2 & 4 |
| `deep` | 2 | `deep` | Reserved for Stories 2 & 4 |

Base fields present at all depths: `event_type`, `schema_version`, `manifest_depth`, `gate_name`, `session_id`, `worktree_id`, `tier`, `timestamp`, `gate_verdicts`, `evidence_ref`, `affects_fields`, `data`.

---

## Forward-Compat Contract

Readers MUST accept unknown `schema_version` by falling back to minimal-tier interpretation:

1. If `schema_version` is present and is an integer > 2, emit a warning to stderr: `[DSO WARN] preconditions reader: unknown schema_version=<N> for ticket <id> — falling back to minimal-tier interpretation`
2. The warning MUST be deduplicated: once per `(ticket_id, schema_version)` pair per process lifetime (use a tmp-dir state file keyed on `<ticket_id>_v<schema_version>`).
3. Readers MUST NOT exit non-zero solely because `schema_version` is unrecognized.
4. Readers MUST return whatever fields are present in the JSON (best-effort extraction).

### Canonical parsing prefix

The parser MUST match events by inspecting the `event_type` field: `"PRECONDITIONS"`. Filename suffix `*-PRECONDITIONS.json` is used for file discovery only; `event_type` in JSON is authoritative for filtering. `schema_version` governs field availability, not event identity.

---

## Degradation Data Sub-Keys

The `data` object in a PRECONDITIONS event may carry the following sub-keys when the event records a graceful-degradation fallthrough. All three fields are optional and have null-coalescing semantics: readers MUST NOT reject events where any of these fields is absent — treat absent as the stated default.

### `data.degradation`

- **Type**: boolean
- **Optional**: yes; default `false` when absent
- **Description**: Indicates this PRECONDITIONS event records a graceful-degradation fallthrough. When `true`, the sprint orchestrator should record a `decision_id` for this event and require an ACK before story closure (see `check-unacked-degradations.sh` and `contracts/ack-event-format.md`).
- **Null-coalescing contract**: readers MUST treat an absent `data.degradation` field identically to `false`. Readers MUST NOT raise an error or warning when the field is absent.

### `data.degradation_type`

- **Type**: string enum — one of `inferred_decision` | `unresolved_question`
- **Optional**: yes; present only when `data.degradation=true`; absent otherwise
- **Description**: Classifies the kind of degradation.
  - `inferred_decision` — the orchestrator made an inference in place of an explicit user decision.
  - `unresolved_question` — a precondition question could not be resolved and was deferred.
- **Null-coalescing contract**: readers MUST treat an absent `data.degradation_type` field as if no type classification is available. Readers MUST NOT reject events where `data.degradation=true` but `data.degradation_type` is absent (older emitter versions may omit it).

### `data.condition_text`

- **Type**: string
- **Optional**: yes; absent for events written before this field was introduced
- **Description**: Human-readable description of the precondition that was degraded. Used by `preconditions-ack` for 3-word-window rationale validation — the validator checks that the `if_skipped` rationale in the ACK event references key words from `condition_text`.
- **Null-coalescing contract**: readers MUST treat an absent `data.condition_text` field as if no condition text is available. `preconditions-ack` MUST skip the 3-word-window validation step when this field is absent.

---

## Reserved `data` Sub-Keys

The following `data` sub-keys are reserved. No other component may introduce fields with these names without updating this contract:

| Key | Introduced in | Notes |
|---|---|---|
| `degradation` | epic 736d-b957 | Graceful-degradation flag; see above |
| `degradation_type` | epic 736d-b957 | Degradation classifier; see above |
| `condition_text` | epic 736d-b957 | Human-readable precondition description; see above |

Future additions to `data` sub-keys must be listed here before the emitting code is merged.

---

## Spike Disclaimer

This contract is defined during the spike story 86ad-f5e7. The `manifest_depth` field-set extensions for `standard` and `deep` tiers (additional fields beyond the base set) are intentionally left as reserved/TBD for Stories 2 and 4 of epic 736d-b957. Only the classifier, writer derivation, and reader forward-compat are implemented in this story.
