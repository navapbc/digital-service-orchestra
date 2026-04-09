# Contract: BRIDGE_ALERT Event Format

- Status: accepted
- Scope: ticket-system-v3 / Jira bridge (epic w22-338o and successors)
- Date: 2026-03-21

## Signal Name

`BRIDGE_ALERT`

---

## Purpose

A `BRIDGE_ALERT` event file is written to a ticket's `.tickets-tracker/<ticket-id>/` directory
whenever the Jira bridge detects a condition that requires operator attention and halts normal
processing for that ticket. Conditions include:

- **Status flap** (outbound): a ticket has oscillated between statuses more than `flap_threshold`
  times within the flap detection window.
- **Unmapped status** (inbound): Jira returned a status value that is absent from
  `INBOUND_STATUS_MAPPING`.
- **Unmapped type** (inbound): Jira returned an issue type that is absent from
  `INBOUND_TYPE_MAPPING`.
- **Destructive change blocked** (inbound): an inbound Jira update would have overwritten a
  non-empty local description, removed relationships, or downgraded the ticket type.
- **Relationship rejection** (inbound): Jira rejected a relationship push; the local relationship
  is preserved unmodified.

`BRIDGE_ALERT` events are **informational only** — they do not alter the compiled ticket state.
Reducers and `.claude/scripts/dso ticket list` ignore them; operators must inspect them manually.

---

## Emitters

| Emitter | Function | Trigger condition |
|---------|----------|-------------------|
| `plugins/dso/scripts/bridge-outbound.py` # shim-exempt: internal implementation path | `write_bridge_alert()` | STATUS flap detected |
| `plugins/dso/scripts/bridge-inbound.py` # shim-exempt: internal implementation path | `write_bridge_alert()` | Unmapped status, unmapped type, destructive change blocked, relationship rejection |

---

## File Naming

Files follow the standard ticket event naming convention defined in `ticket-event-format.md`:

```
<timestamp>-<uuid>-BRIDGE_ALERT.json
```

Example: `1742605200-3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c-BRIDGE_ALERT.json`

The file is written inside `.tickets-tracker/<ticket-id>/` and is committed to the tickets branch
alongside other event files.

---

## Canonical Field Schema

| Field        | Type    | Required | Description |
|--------------|---------|----------|-------------|
| `event_type` | string  | yes      | Always `"BRIDGE_ALERT"`. |
| `timestamp`  | integer | yes      | UTC epoch seconds at the moment the alert was written. |
| `uuid`       | string  | yes      | UUID4 unique event identifier (lowercase, hyphens preserved). |
| `env_id`     | string  | yes      | UUID4 identifying the bridge environment (value of `.tickets-tracker/.env-id`). Empty string `""` is allowed when emitted in environments without a configured env-id; parsers must not reject it. |
| `ticket_id`  | string  | yes      | Local ticket ID (e.g., `"w21-5mr1"` or `"jira-dso-99"`). |
| `data`       | object  | yes      | Event-specific payload. Must contain at least `"reason"` (see below). |

### `data` fields

| Field    | Type   | Required | Description |
|----------|--------|----------|-------------|
| `reason` | string | yes      | Human-readable description of what triggered the alert. Must be non-empty. |

### Field constraints

- `event_type`: must equal `"BRIDGE_ALERT"` exactly (case-sensitive).
- `timestamp`: positive integer; UTC epoch seconds; must not be zero.
- `uuid`: UUID4, lowercase with hyphens (e.g., `"3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"`).
- `env_id`: UUID4, lowercase with hyphens; empty string `""` is permitted.
- `ticket_id`: non-empty string matching the local ticket ID convention.
- `data.reason`: non-empty string; no length limit enforced, but must identify the alert class and
  the specific value(s) involved (e.g., `"Unknown status value: 'Waiting for approval'"`).

### Canonical parsing prefix

The parser MUST match against:

- `BRIDGE_ALERT` — the `event_type` field value. Any event file whose `event_type` equals `"BRIDGE_ALERT"` (case-sensitive) is a valid BRIDGE_ALERT event. File-level identification uses the filename suffix `-BRIDGE_ALERT.json`.

---

## Canonical Example

```json
{
  "event_type": "BRIDGE_ALERT",
  "timestamp": 1742605200,
  "uuid": "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c",
  "env_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "ticket_id": "jira-dso-99",
  "data": {
    "reason": "Unknown status value: 'Waiting for approval'"
  }
}
```

---

## Implementation Divergence (pre-canonicalization)

As of 2026-03-21, the two `write_bridge_alert()` implementations do not yet match this canonical
schema. The divergences are:

| Field | `bridge-outbound.py` | `bridge-inbound.py` | Canonical |
|-------|----------------------|---------------------|-----------|
| `uuid` | present | **absent** | required |
| `ticket_id` | present | **absent** | required |
| `data.reason` | `data: {"reason": ...}` | top-level `reason` field | `data: {"reason": ...}` |

The `bridge-inbound.py` emitter must be updated to:
1. Add `uuid` (a new `uuid.uuid4()` generated at write time).
2. Add `ticket_id` (passed through from the calling context).
3. Move `reason` inside a `data` object (removing the top-level `reason` field).

Until that migration is complete, consumers reading `BRIDGE_ALERT` files must handle both layouts:
- Canonical layout: `data.reason` present.
- Legacy inbound layout: top-level `reason` present, `uuid` and `ticket_id` absent.

---

## Relationship to Other Event Contracts

- **`ticket-event-format.md`**: defines the base schema that all ticket event files share
  (`timestamp`, `uuid`, `event_type`, `env_id`, `data`). `BRIDGE_ALERT` adopts this base schema
  and adds `ticket_id` as a denormalized convenience field.
- **`sync-event-format.md`**: defines the `SYNC` event written by the outbound bridge on
  successful Jira push. `BRIDGE_ALERT` and `SYNC` are mutually exclusive outcomes for a given
  bridge processing attempt on a ticket.
- `BRIDGE_ALERT` files are **not** consumed by the ticket reducer (`ticket-reducer.py`) and do not
  affect compiled ticket state. They exist solely as an operator-visible audit trail.
