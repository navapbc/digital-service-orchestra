# Contract: Comment Sync Dedup Interface

- Status: accepted
- Scope: ticket-system-v3 / Jira bridge (epic w21-bwfw)
- Date: 2026-03-21

## Purpose

This document defines the dedup interface between the outbound Jira bridge (emitter) and the inbound Jira bridge (parser) for preventing echo-imported comments. The outbound bridge embeds a UUID marker in each Jira comment it pushes; the inbound bridge uses Jira comment IDs and the per-ticket dedup state file to skip re-importing comments that originated locally.

---

## Signal Name

`COMMENT` (outbound emitter) / `getComments` (inbound parser via ACLI)

---

## Emitter

`plugins/dso/scripts/bridge-outbound.py` # shim-exempt: internal implementation path reference

The outbound bridge embeds a UUID marker in every Jira comment it creates so the inbound bridge can
identify comments that originated locally and skip them during pull (echo prevention).

---

## Parser

Inbound bridge — story w21-dww7

The inbound bridge reads Jira comments via ACLI `getComments`, checks each comment's Jira comment ID
against the dedup state file, and optionally extracts the UUID marker from the comment body. It must
use the Jira comment ID as the primary dedup key and treat the UUID marker as secondary confirmation
only.

---

## UUID Marker Format

A local COMMENT event's UUID is embedded in the Jira comment body as an HTML comment on the **last
line** of the comment text:

```
<!-- origin-uuid: {event_uuid} -->
```

Where `{event_uuid}` is the UUID4 of the local COMMENT event that triggered the push (e.g.,
`3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c`).

**Rendering behavior**: The HTML comment is invisible in Jira's rendered view but present in the raw
body text returned by `getComments`.

**Stripping risk**: Jira's rich-text editor may strip the HTML comment when a user edits the Jira
comment. Inbound parsers MUST NOT rely on the marker being present for dedup correctness; it is used
only as secondary confirmation.

### Canonical parsing prefix

The parser MUST match against:

- `<!-- origin-uuid:` — prefix match on the last line of a Jira comment body. Any line beginning with `<!-- origin-uuid:` is a valid UUID marker embedded by the outbound bridge. The UUID follows immediately after the space: `<!-- origin-uuid: {event_uuid} -->`.

---

## Dedup State File

**Path**: `.tickets-tracker/<ticket-id>/.jira-comment-map`

**Format**: JSON object with two keys:

```json
{
  "uuid_to_jira_id": {
    "<event_uuid>": "<jira_comment_id>"
  },
  "jira_id_to_uuid": {
    "<jira_comment_id>": "<event_uuid>"
  }
}
```

### Schema

| Key                | Type                   | Description                                                         |
|--------------------|------------------------|---------------------------------------------------------------------|
| `uuid_to_jira_id`  | object (string→string) | Maps local event UUID → Jira comment ID. Written by outbound bridge after successful comment push. |
| `jira_id_to_uuid`  | object (string→string) | Maps Jira comment ID → local event UUID. Inverse index; used by inbound bridge for O(1) dedup lookups. |

Both dicts are kept in sync: every entry written to one dict must have a corresponding entry in the
other. An absent key in either dict means no mapping exists (not an error).

---

## Dedup Keys

### Primary dedup key (inbound): Jira comment ID

The Jira comment ID is present in every comment object returned by ACLI `getComments`. It survives
rich-text editor operations that may strip HTML markers. The inbound bridge MUST use the Jira comment
ID as the authoritative dedup key by checking `jira_id_to_uuid` in the dedup state file.

### Secondary dedup key (inbound): UUID marker

The UUID extracted from `<!-- origin-uuid: ... -->` in the comment body. Used to confirm that a
comment originated locally, but NOT relied upon when the marker is absent (stripped by editor). If
the marker is present and the UUID is found in `uuid_to_jira_id`, the bridge may use this as
additional confirmation that the comment was pushed by local outbound.

---

## Outbound Echo Prevention

Before writing a local COMMENT event on inbound pull, the inbound bridge MUST:

1. Check `jira_id_to_uuid` in `.tickets-tracker/<ticket-id>/.jira-comment-map`.
2. If the Jira comment ID is present as a key, **skip** — the comment was pushed by local outbound
   and must not be re-imported as a new local event.
3. If the Jira comment ID is absent, proceed with importing the comment as a new local COMMENT event.

---

## Outbound Write Protocol

After the outbound bridge successfully pushes a local COMMENT event to Jira and receives a Jira
comment ID in response:

1. Read `.tickets-tracker/<ticket-id>/.jira-comment-map` (create empty structure if absent).
2. Add `event_uuid → jira_comment_id` to `uuid_to_jira_id`.
3. Add `jira_comment_id → event_uuid` to `jira_id_to_uuid`.
4. Write the updated file atomically (write to temp file, rename).

---

## Example

Dedup state file after one comment has been pushed:

```json
{
  "uuid_to_jira_id": {
    "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c": "10042"
  },
  "jira_id_to_uuid": {
    "10042": "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"
  }
}
```

Jira comment body (last line is the marker):

```
This is the comment text written by the local bridge.
<!-- origin-uuid: 3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c -->
```

---

## Relationship to SYNC Event Format

This contract governs comment-level dedup between local COMMENT events and Jira comments. It is
distinct from the SYNC event format (`sync-event-format.md`), which governs issue-level
synchronization signals. The `.jira-comment-map` file is a per-ticket side-channel state file; it is
not a ticket event file and is not committed to the event log.
