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
| `<timestamp>` | UTC epoch nanoseconds (integer), unpadded (currently 19 digits) |
| `<uuid>`      | Lowercase UUID4, hyphens preserved                  |
| `<TYPE>`      | Uppercase event type: `CREATE`, `STATUS`, `COMMENT`, `LINK`, `UNLINK`, `SNAPSHOT`, or `SYNC` |

**Example**: `1742605200123456789-3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c-CREATE.json`

**Parsing rule**: To extract TYPE from a filename, split on the last `-` before `.json`. The timestamp is everything before the first `-`. The UUID is the portion between the first `-` and the last `-` before `.json`.

All current UTC epoch nanosecond timestamps are 19 digits, ensuring lexicographic sort equals chronological sort. The digit count is stable for the foreseeable future.

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
| `timestamp`  | integer           | UTC epoch nanoseconds at the time the event was written  |
| `uuid`       | string (UUID4)    | Unique event identifier; lowercase, hyphens preserved    |
| `event_type` | string (enum)     | One of: `CREATE`, `STATUS`, `COMMENT`, `LINK`, `UNLINK`, `SNAPSHOT`, `SYNC` |
| `env_id`     | string (UUID4)    | Value of `.tickets-tracker/.env-id` at write time        |
| `author`     | string            | `git user.name` of the writer (informational only — not used for attribution or access control; `env_id` provides machine identity) |
| `data`       | object            | Event-type-specific payload (see below)                  |

### `data` fields by `event_type`

#### `CREATE`

```json
{
  "ticket_type": "<bug|epic|story|task>",
  "title": "<string>",
  "parent_id": "<string|null>",
  "description": "<string|null>"
}
```

| Field          | Type          | Description                                                                 |
|----------------|---------------|-----------------------------------------------------------------------------|
| `ticket_type`  | string (enum) | One of: `bug`, `epic`, `story`, `task`.                                    |
| `title`        | string        | Non-empty ticket title. Must be ≤ 255 characters for Jira sync.            |
| `parent_id`    | string\|null  | ID of an existing parent ticket, or `null` if top-level.                   |
| `description`  | string\|null  | Optional long-form description text. `null` or absent when not provided.   |

#### `STATUS`

```json
{
  "status": "<open|in_progress|closed|blocked>",
  "current_status": "<string>"
}
```

| Field            | Type   | Description                                                                 |
|------------------|--------|-----------------------------------------------------------------------------|
| `status`         | string | The target status. One of: `open`, `in_progress`, `closed`, `blocked`.     |
| `current_status` | string | The status the writer read before transitioning (optimistic concurrency proof). The reducer must apply this event only if the ticket's current compiled status matches this value; otherwise it should flag a conflict. |

#### `COMMENT`

```json
{
  "body": "<string>"
}
```

| Field  | Type   | Description                          |
|--------|--------|--------------------------------------|
| `body` | string | The comment text. Must be non-empty. |

#### `LINK`

```json
{
  "relation": "blocks|depends_on|relates_to",
  "target_id": "<ticket-id>"
}
```

| Field       | Type   | Description                                                                                         |
|-------------|--------|-----------------------------------------------------------------------------------------------------|
| `relation`  | string | The dependency direction. One of: `blocks`, `depends_on`, `relates_to`.                            |
| `target_id` | string | The ticket ID that is the target of this relationship.                                              |

**Note**: `relates_to` links generate reciprocal LINK events in both ticket directories — one in the source ticket's directory and one in the target ticket's directory, each pointing at the other.

#### `UNLINK`

```json
{
  "link_uuid": "<uuid of the LINK event being negated>",
  "target_id": "<ticket-id>"
}
```

| Field       | Type   | Description                                                                                         |
|-------------|--------|-----------------------------------------------------------------------------------------------------|
| `link_uuid` | string | The `uuid` field of the LINK event this UNLINK cancels. Used by reducers to remove the link from the net-active set. |
| `target_id` | string | The ticket ID that was the target of the cancelled LINK (denormalized for readability; the authoritative reference is `link_uuid`). |

**Note**: For `relates_to` unlinks, a reciprocal UNLINK event is written in the target ticket's directory as well.

### Event Type Contracts: Definition Status

| Event Type | `data` Fields Defined In | Story    | Status   |
|------------|--------------------------|----------|----------|
| `CREATE`   | This document (above)    | w21-ablv | defined  |
| `STATUS`   | This document (above)    | w21-o72z | defined  |
| `COMMENT`  | This document (above)    | w21-o72z | defined  |
| `LINK`     | This document (above)    | w21-k2yz | defined  |
| `UNLINK`   | This document (above)    | w21-k2yz | defined  |
| `SNAPSHOT` | Story contract           | w21-q0nn | forward-reference |
| `SYNC`     | Story contract           | w21-54wx (Epic 3) | forward-reference |

---

## Reducer Ordering Guarantee

Events are sorted by **filename** (lexicographic sort) before reduction.

Because filenames are prefixed with the UTC epoch nanosecond timestamp (19 digits), lexicographic sort is equivalent to chronological sort. The nanosecond precision means same-nanosecond collisions are extremely unlikely; UUID provides a tie-break when they occur.

This ordering guarantee is:
- **Deterministic**: the sort key is embedded in the filename.
- **Reproducible across environments**: no local clock drift affects the final sort order once the file is written.
- **Independent of filesystem ordering**: reducers must always sort explicitly; they must not rely on `readdir` order.

Any reducer that processes `.tickets-tracker/<ticket-id>/` event files **must** sort the full list of filenames lexicographically before applying events.

**Invariant**: Duplicate filenames (identical timestamp, UUID, and TYPE) are a system integrity violation. If detected, the reducer **must** report an error via `.claude/scripts/dso ticket fsck` rather than silently choosing one. UUID4 collision probability is negligible (~2^-122), so duplicate filenames indicate a bug, not a tie to break.

---

## Ghost Prevention

A **ghost ticket** is a ticket directory (`.tickets-tracker/<ticket-id>/`) that contains no parseable `CREATE` event. Ghost tickets arise from partially failed writes or manual directory creation. The system enforces two layers of ghost prevention:

### Reducer-level (read path)

When `ticket-reducer.py` processes a ticket directory:

- **No event files**: returns `None` (directory ignored by `.claude/scripts/dso ticket list`).
- **All event files are corrupt JSON** (none parse): returns an error-state dict with `status='error'` and `error='no_valid_create_event'`. The ticket is surfaced in `.claude/scripts/dso ticket list` with `status='error'` rather than crashing.
- **Event files present but no parseable CREATE**: same as above — `status='error'`, `error='no_valid_create_event'`.
- **Corrupt CREATE event** (parseable JSON but missing required `ticket_type` or `title`): returns error-state dict with `status='fsck_needed'` and `error='corrupt_create_event'`.

All error-state dicts include the full standard schema fields (`ticket_type`, `title`, `author`, etc.) with sentinel defaults (`None` or empty) so consumers never crash on missing keys. The `status` field is `"error"` or `"fsck_needed"`, and the `error` field describes the specific failure. Error-state tickets are excluded from `ticket list` default output unless explicitly requested via `--status=error` or `--status=fsck_needed`.

### Command-level (write path)

Before writing a `STATUS` or `COMMENT` event, the `.claude/scripts/dso ticket transition` and `.claude/scripts/dso ticket comment` subcommands check that the ticket directory contains at least one `*-CREATE.json` file. If no `CREATE` event exists:

- `.claude/scripts/dso ticket transition <ghost_id> ...` → exits non-zero with `Error: ticket <id> has no CREATE event`.
- `.claude/scripts/dso ticket comment <ghost_id> ...` → exits non-zero with `Error: ticket <id> has no CREATE event`.

This prevents ghost tickets from accumulating additional events that would be silently ignored by the reducer.
