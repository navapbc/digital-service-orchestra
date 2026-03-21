# Contract: Ticket Event File Format and Reducer Ordering Interface

- Status: accepted
- Scope: ticket-system-v3 (epic w21-ablv)
- Date: 2026-03-20

## Purpose

This document defines the cross-story contract for:
1. Event file naming convention
2. Directory layout for the `.tickets-tracker/` store
3. JSON event base schema (fields shared by all event types)
4. Reducer ordering guarantee

All stories in the ticket-system-v3 epic that read or write event files **must** conform to this contract.

---

## Event File Naming Convention

```
<timestamp>-<uuid>-<TYPE>.json
```

| Component     | Format                                              |
|---------------|-----------------------------------------------------|
| `<timestamp>` | UTC epoch seconds (integer), unpadded (currently 10 digits; grows naturally) |
| `<uuid>`      | Lowercase UUID4, hyphens preserved                  |
| `<TYPE>`      | Uppercase event type: `CREATE`, `STATUS`, `COMMENT`, `LINK`, `SNAPSHOT`, or `SYNC` |

**Example**: `1742605200-3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c-CREATE.json`

**Parsing rule**: To extract TYPE from a filename, split on the last `-` before `.json`. The timestamp is everything before the first `-`. The UUID is the portion between the first `-` and the last `-` before `.json`.

All current UTC epoch timestamps are 10 digits (since 2001-09-09), ensuring lexicographic sort equals chronological sort. When timestamps grow to 11 digits (2286-11-20), lexicographic sort remains correct because all existing filenames share the same digit count within any realistic system lifetime.

---

## Directory Layout

```
.tickets-tracker/
  <ticket-id>/
    <timestamp>-<uuid>-<TYPE>.json   # event files, committed to tickets branch
    .state-cache                      # compiled-state cache, gitignored on tickets branch
  .env-id                             # UUID4 environment identity, gitignored on tickets branch
```

- Event files under `<ticket-id>/` are committed to the `tickets` branch.
- `.state-cache` is a per-ticket compiled-state cache; it is listed in `.gitignore` on the tickets branch and **must not** be committed.
- `.env-id` contains a single UUID4 that uniquely identifies the local environment; it is also gitignored on the tickets branch and **must not** be committed.

---

## JSON Event Base Schema

All event files are valid JSON objects containing the following base fields:

| Field        | Type              | Description                                              |
|--------------|-------------------|----------------------------------------------------------|
| `timestamp`  | integer           | UTC epoch seconds at the time the event was written      |
| `uuid`       | string (UUID4)    | Unique event identifier; lowercase, hyphens preserved    |
| `event_type` | string (enum)     | One of: `CREATE`, `STATUS`, `COMMENT`, `LINK`, `SNAPSHOT`, `SYNC` |
| `env_id`     | string (UUID4)    | Value of `.tickets-tracker/.env-id` at write time        |
| `author`     | string            | `git user.name` of the writer (informational only — not used for attribution or access control; `env_id` provides machine identity) |
| `data`       | object            | Event-type-specific payload (see below)                  |

### `data` fields by `event_type`

Only `CREATE` is defined in this document. Other event types are defined in their respective story contracts (see Forward Reference table below).

#### `CREATE`

```json
{
  "ticket_type": "<bug|epic|story|task>",
  "title": "<string>",
  "parent_id": "<string|null>"
}
```

### Forward Reference: Event Type Contracts

| Event Type | `data` Fields Defined In | Story |
|------------|--------------------------|-------|
| `CREATE`   | This document (above)    | w21-ablv |
| `STATUS`   | Story contract           | w21-o72z |
| `COMMENT`  | Story contract           | w21-o72z |
| `LINK`     | Story contract           | w21-o72z |
| `SNAPSHOT`  | Story contract          | w21-q0nn |
| `SYNC`     | Story contract           | w21-54wx (Epic 3) |

---

## Reducer Ordering Guarantee

Events are sorted by **filename** (lexicographic sort) before reduction.

Because filenames are prefixed with the UTC epoch timestamp (currently 10 digits), lexicographic sort is equivalent to chronological sort. For events written within the same second, the UUID component provides a stable, deterministic tie-break (lexicographic on the UUID string).

This ordering guarantee is:
- **Deterministic**: the sort key is embedded in the filename.
- **Reproducible across environments**: no local clock drift affects the final sort order once the file is written.
- **Independent of filesystem ordering**: reducers must always sort explicitly; they must not rely on `readdir` order.

Any reducer that processes `.tickets-tracker/<ticket-id>/` event files **must** sort the full list of filenames lexicographically before applying events.

**Invariant**: Duplicate filenames (identical timestamp, UUID, and TYPE) are a system integrity violation. If detected, the reducer **must** report an error via `ticket fsck` rather than silently choosing one. UUID4 collision probability is negligible (~2^-122), so duplicate filenames indicate a bug, not a tie to break.
