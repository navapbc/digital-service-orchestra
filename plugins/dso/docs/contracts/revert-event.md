# Contract: REVERT Event Emit/Parse Interface

- Status: accepted
- Scope: ticket-system-v3 / bridge observability and recovery (epic w21-bwfw, story w21-qjcy)
- Date: 2026-03-21

## Purpose

This document defines the emit/parse interface for the `REVERT` ticket event, which records that an earlier ticket event is being undone. The emitter (`ticket-revert.sh`) writes the event to the ticket's event log; parsers (`ticket-reducer.py` and `bridge-outbound.py`) read it to build compiled state and apply check-before-overwrite semantics when pushing the revert's outbound effect to Jira.

---

## Signal Name

`REVERT`

---

## Emitter

`ticket-revert.sh` (via `write_commit_event` in `ticket-lib.sh`)

The `.claude/scripts/dso ticket revert` subcommand writes a REVERT event into the target ticket's
`.tickets-tracker/<ticket-id>/` directory. The event records which earlier event is being
reverted and who initiated it. The emitter **must** validate that the target event is not itself a
REVERT event before writing (see [REVERT-of-REVERT constraint](#revert-of-revert-constraint)
below).

---

## Parsers

| Parser | Role |
|---|---|
| `ticket-reducer.py` | Reads REVERT events and appends entries to a `reverts` list in the compiled ticket state. The reducer does **not** automatically undo the target event's effect — undo logic is event-type-specific and is handled by `bridge-outbound.py`. |
| `bridge-outbound.py` | When processing a REVERT whose `data.target_event_type` is `STATUS` or `SYNC`, fetches current Jira state before pushing the revert's outbound effect. Emits a `BRIDGE_ALERT` if Jira has diverged since the original bad action (check-before-overwrite). |

---

## Fields

All REVERT events conform to the base schema defined in `ticket-event-format.md`. The table below
lists all fields, including base-schema fields, for completeness.

| Field | Type | Required | Description |
|---|---|---|---|
| `event_type` | string | yes | Always `"REVERT"`. The parser must validate this value and reject other strings. |
| `timestamp` | integer | yes | UTC epoch seconds at the moment the event was written. |
| `uuid` | string (UUID4) | yes | Unique event identifier; lowercase, hyphens preserved (e.g., `"3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"`). |
| `env_id` | string (UUID4) | yes | Value of `.tickets-tracker/.env-id` at write time; identifies the environment that emitted the event. |
| `author` | string | yes | `git user.name` of the initiator. Informational only — `env_id` is the authoritative machine identity. |
| `data.target_event_uuid` | string (UUID4) | yes | The `uuid` of the event being reverted. Must reference a non-REVERT event (see constraint). |
| `data.target_event_type` | string | yes | The `event_type` of the event being reverted (e.g., `"STATUS"`, `"SYNC"`). Must not be `"REVERT"`. |
| `data.reason` | string | no | Human-readable explanation of why the revert was initiated. Empty string is allowed; `null` is not. |

### Field constraints

- `event_type`: must equal the string `"REVERT"` exactly (case-sensitive); parsers must reject any
  other value.
- `timestamp`: positive integer; UTC epoch seconds; must not be zero.
- `uuid`: UUID4 in lowercase with hyphens; must be unique across all events in the ticket's event
  log (duplicate UUIDs indicate a system integrity violation — see `ticket-event-format.md`
  invariant).
- `env_id`: UUID4 in lowercase with hyphens.
- `author`: non-empty string; must not be `null`.
- `data.target_event_uuid`: non-empty UUID4 string; must reference a real event in the ticket's
  event directory; must not reference a REVERT event (enforced at CLI level — see constraint).
- `data.target_event_type`: non-empty string matching a known event type; must not be `"REVERT"`.
- `data.reason`: string; may be empty (`""`); must not be `null`.

---

## Event File Naming

Follows the standard naming convention from `ticket-event-format.md`:

```
<timestamp>-<uuid>-REVERT.json
```

Example: `1742605200-3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c-REVERT.json`

---

## Example

Representative REVERT event JSON payload:

```json
{
  "event_type": "REVERT",
  "timestamp": 1742605200,
  "uuid": "7a8b9c0d-1e2f-3a4b-5c6d-7e8f9a0b1c2d",
  "env_id": "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c",
  "author": "Jane Developer",
  "data": {
    "target_event_uuid": "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
    "target_event_type": "STATUS",
    "reason": "Status was advanced to closed prematurely; reverting to in_progress"
  }
}
```

Example with empty `reason` (reason is optional):

```json
{
  "event_type": "REVERT",
  "timestamp": 1742691600,
  "uuid": "b2c3d4e5-f6a7-8b9c-0d1e-2f3a4b5c6d7e",
  "env_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "author": "Joe Developer",
  "data": {
    "target_event_uuid": "9f8e7d6c-5b4a-3928-1716-151413121110",
    "target_event_type": "SYNC",
    "reason": ""
  }
}
```

---

## REVERT-of-REVERT Constraint

**REVERTs may only target non-REVERT events.**

`ticket-revert.sh` must validate, before writing a REVERT event, that the target event's
`event_type` is not `"REVERT"`. If the target is a REVERT event, the CLI must exit non-zero with:

```
Error: cannot revert a REVERT event (REVERT-of-REVERT is not allowed). Target event <uuid> has type REVERT.
```

This constraint is enforced at the CLI level only — the reducer does not re-validate it. Callers
must not rely on the reducer to catch REVERT-of-REVERT; the emitter is the enforcement point.

**Rationale**: REVERT-of-REVERT creates ambiguous causality chains and makes compiled state
difficult to reason about. If a revert itself needs to be undone, the correct action is to re-apply
the original change as a new event (e.g., a new STATUS event), not to chain REVERTs.

### Canonical parsing prefix

The parser MUST match against:

- `REVERT` — the `event_type` field value. Any event file whose `event_type` equals `"REVERT"` (case-sensitive) is a valid REVERT event. File-level identification uses the filename suffix `-REVERT.json`.

---

## Reducer Semantics

When `ticket-reducer.py` encounters a REVERT event during reduction:

1. The event is appended to a `reverts` list in the compiled ticket state. Each entry records at
   minimum: `{ "uuid": "<revert-event-uuid>", "target_event_uuid": "...", "target_event_type": "...", "timestamp": ..., "author": "..." }`.
2. The reducer does **not** automatically undo the target event's effect. Undo logic is
   event-type-specific and is handled by `bridge-outbound.py` when it processes the REVERT for
   outbound sync.
3. The compiled state `reverts` list is ordered by the reducer's standard lexicographic filename
   sort (same as all events — see `ticket-event-format.md`).

### Example compiled-state fragment

```json
{
  "reverts": [
    {
      "uuid": "7a8b9c0d-1e2f-3a4b-5c6d-7e8f9a0b1c2d",
      "target_event_uuid": "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
      "target_event_type": "STATUS",
      "timestamp": 1742605200,
      "author": "Jane Developer"
    }
  ]
}
```

---

## Bridge-Outbound Semantics (Check-Before-Overwrite)

When `bridge-outbound.py` processes a REVERT event whose `data.target_event_type` is `"STATUS"` or
`"SYNC"`, it must:

1. **Fetch current Jira state** for the affected Jira issue before pushing the revert's outbound
   effect.
2. **Compare** the fetched Jira state against the state recorded at the time of the original
   (now-reverted) event.
3. **If Jira has diverged** since the original bad action (i.e., someone or another process has
   already changed Jira independently), emit a `BRIDGE_ALERT` event (see `bridge-alert-event.md`)
   and **do not push** the revert. The BRIDGE_ALERT must include a human-readable `reason`
   describing the divergence.
4. **If Jira has not diverged**, push the revert's intended change to Jira.

For REVERT events targeting `COMMENT`, `bridge-outbound.py` does not perform a Jira fetch (no Jira
deletion; orphaned comments are expected post-REVERT state as described below).

For REVERT events targeting `LINK` or `UNLINK`, `bridge-outbound.py` pushes the corresponding
inverse operation to Jira (remove the link for a reverted LINK; re-add the link for a reverted
UNLINK) without a pre-fetch check. If the Jira link operation fails (e.g., the link was already
removed or the target issue is not found), the bridge emits a `BRIDGE_ALERT` instead of retrying.

### Comment interaction

Reverting a ticket action that previously caused Jira comments to be synced **does not** delete
those Jira comments. Orphaned Jira comments are accepted as known post-REVERT state and require
manual cleanup. This is intentional — the Jira API does not guarantee comment deletion, and
attempting it introduces more failure modes than it resolves. This behavior must be documented to
operators using `bridge-status` or `bridge-fsck` output.

---

## Relationship to Other Event Types

| Event Type | How REVERT interacts |
|---|---|
| `STATUS` | Primary REVERT target; bridge-outbound performs check-before-overwrite |
| `SYNC` | Primary REVERT target; bridge-outbound performs check-before-overwrite |
| `COMMENT` | Can be reverted (no Jira deletion; orphaned comments are expected post-REVERT state) |
| `LINK` / `UNLINK` | Can be reverted; bridge-outbound pushes the inverse Jira link operation (no pre-fetch check); emits `BRIDGE_ALERT` on failure |
| `CREATE` | Reverting a CREATE is not supported (use `ticket close` or `.claude/scripts/dso ticket fsck` for cleanup) |
| `REVERT` | Cannot be reverted — REVERT-of-REVERT is rejected by the CLI |
| `BRIDGE_ALERT` | Cannot be reverted — alerts are informational; use `bridge-fsck` for resolution |

---

## Relationship to Ticket Event Base Schema

REVERT is a full ticket event file (committed to `.tickets-tracker/<ticket-id>/` on the `tickets`
branch), not a bridge-layer signal like the SYNC event in `sync-event-format.md`. It conforms to
the base schema (`ticket-event-format.md`) and uses the standard `data` wrapper.
