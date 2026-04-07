# Contract: SYNC Event Format

- Status: accepted
- Scope: ticket-system-v3 / Jira bridge (epic w21-bwfw)
- Date: 2026-03-21

## Purpose

This document defines the SYNC event payload format used by the Jira bridge to signal that a local ticket change is ready to be pushed to Jira. The outbound bridge (`bridge-outbound.py`) emits this payload; the inbound bridge consumes it to apply the change idempotently using `jira_key`, `local_id`, and `run_id` for correlation.

---

## Signal Name

`SYNC`

---

## Emitter

`plugins/dso/scripts/bridge-outbound.py` # shim-exempt: internal implementation path reference

The outbound bridge emits a SYNC event payload when a local ticket change is ready to be pushed to
Jira. Each SYNC event carries enough information for the inbound bridge to correlate the local
ticket with its Jira counterpart and apply the change idempotently.

---

## Parser

Inbound bridge — story w21-gykt

The inbound bridge consumes SYNC events emitted by `bridge-outbound.py`. It uses `jira_key` to
identify the target Jira issue, `local_id` to correlate with the local ticket store, and `run_id`
for GHA traceability. The parser must treat all fields as required and reject payloads that are
missing any field.

---

## Fields

| Field        | Type    | Required | Description                                                                                     |
|--------------|---------|----------|-------------------------------------------------------------------------------------------------|
| `event_type` | string  | yes      | Always `"SYNC"`. The parser must validate this value and reject other strings.                  |
| `jira_key`   | string  | yes      | The Jira issue key corresponding to the local ticket (e.g., `"DSO-42"`).                       |
| `local_id`   | string  | yes      | The local ticket ID in the `.tickets-tracker/` store (e.g., `"w21-5mr1"`).                     |
| `env_id`     | string  | yes      | UUID4 identifying the bridge environment (value of `.tickets-tracker/.env-id` at emit time).    |
| `timestamp`  | integer | yes      | UTC epoch seconds at the moment the event was emitted.                                          |
| `run_id`     | string  | yes      | GitHub Actions run ID for traceability (e.g., `"12345678901"`). Empty string `""` is allowed when emitted outside GHA context; parsers must not reject it. |

### Field constraints

- `event_type`: must equal the string `"SYNC"` exactly (case-sensitive).
- `jira_key`: non-empty string; format is `<PROJECT>-<NUMBER>` (e.g., `"DSO-42"`), but the parser
  must not enforce format beyond non-empty.
- `local_id`: non-empty string matching the local ticket ID convention.
- `env_id`: UUID4 in lowercase with hyphens (e.g., `"3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"`).
- `timestamp`: positive integer; UTC epoch seconds; not zero.
- `run_id`: string; may be empty when emitted outside a GHA context; must not be `null`.

---

## Example

Representative SYNC event JSON payload:

```json
{
  "event_type": "SYNC",
  "jira_key": "DSO-42",
  "local_id": "w21-5mr1",
  "env_id": "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c",
  "timestamp": 1742605200,
  "run_id": "12345678901"
}
```

Example with empty `run_id` (emitted outside GHA context):

```json
{
  "event_type": "SYNC",
  "jira_key": "DSO-17",
  "local_id": "w21-gykt",
  "env_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "timestamp": 1742691600,
  "run_id": ""
}
```

### Canonical parsing prefix

The parser MUST match against:

- `SYNC` — the `event_type` field value. Any SYNC payload whose `event_type` equals `"SYNC"` (case-sensitive) is a valid SYNC event. The parser must validate this field and reject payloads with any other value.

---

## Relationship to Ticket Event Base Schema

The SYNC event payload defined here is a **bridge-layer signal**, not a ticket event file (see
`ticket-event-format.md`). It is transmitted over the Jira bridge channel (e.g., GHA workflow
artifacts or a message queue) rather than committed to the `.tickets-tracker/` git store. The
`timestamp` and `env_id` fields mirror the base schema for consistency, but there is no `uuid`,
`author`, or `data` wrapper — the SYNC payload is flat.
