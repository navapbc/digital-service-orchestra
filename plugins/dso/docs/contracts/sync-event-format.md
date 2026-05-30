# Contract: SYNC Event Format

- Status: accepted
- Scope: ticket-system-v3 / Jira bridge (epic w21-bwfw)
- Date: 2026-03-21

## Purpose

This document defines the SYNC event payload format used by the Jira bridge to signal that a local ticket change is ready to be pushed to Jira. Local SYNC events are emitted by ticket CLI sync operations and consumed by `dso_reconciler.applier` (which translates them into Jira mutations via the band system) to apply the change idempotently using `jira_key`, `local_id`, and `run_id` for correlation.

---

## Signal Name

`SYNC`

---

## Emitter

The ticket CLI sync operations (`.claude/scripts/dso ticket sync`) emit SYNC events
to the local event log when a ticket change is ready to be pushed to Jira. SYNC
events are persisted as `*-SYNC.json` files under the per-ticket directory in the
tickets branch (the event-sourced canonical store).

Each SYNC event carries enough information for the outbound consumer
(`dso_reconciler.applier`) to correlate the local ticket with its Jira counterpart
and apply the change idempotently.

---

## Parser

Reconciler inbound path — story w21-gykt

`dso_reconciler.applier` consumes local SYNC events as the post-cutover outbound consumer (translating SYNC into Jira mutations via the band system). It uses `jira_key` to
identify the target Jira issue, `local_id` to correlate with the local ticket store, and `run_id`
for GHA traceability. The parser must treat all fields as required and reject payloads that are
missing any field.

---

## Fields

| Field        | Type    | Required | Description                                                                                     |
|--------------|---------|----------|-------------------------------------------------------------------------------------------------|
| `event_type` | string  | yes      | Always `"SYNC"`. The parser must validate this value and reject other strings.                  |
| `jira_key`   | string  | yes      | The Jira issue key corresponding to the local ticket (e.g., `"DSO-42"`).                       |
| `local_id`   | string  | yes      | The local ticket ID in the `.tickets-tracker/` store (e.g., `"w21-5mr1"`). <!-- # tickets-boundary-ok -->
| `env_id`     | string  | yes      | UUID4 identifying the bridge environment (value of `.tickets-tracker/.env-id` at emit time). <!-- # tickets-boundary-ok -->
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

SYNC events ARE committed to the tickets branch as `*-SYNC.json` files under
each ticket's directory — they are first-class ticket events, just like CREATE,
STATUS, EDIT, etc. (see `ticket-event-format.md`). Each SYNC event is consumed
by the reconciler's outbound applier (`dso_reconciler.applier`) on the next
scheduled pass; the applier reads SYNC events from the tickets branch as part
of its diff input.

The `timestamp` and `env_id` fields mirror the base ticket-event schema for
consistency, but the SYNC payload is flat — there is no `uuid`, `author`, or
`data` wrapper, because SYNC is a signal-shape event whose payload IS its data.
