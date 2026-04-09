# Contract: Tombstone File Format for Archived Ticket Dependency Resolution

- Status: accepted
- Scope: archive-closed-tickets.sh / .claude/scripts/dso ticket deps (epic w21-6llo)
- Date: 2026-03-21

## Purpose

This document defines the cross-component contract for tombstone files written by
`archive-closed-tickets.sh` and consumed by `.claude/scripts/dso ticket deps`. When a ticket is archived
and a tombstone exists, `.claude/scripts/dso ticket deps` renders it as `[archived: <final_status> (<type>)]`
instead of `[missing — treated as satisfied]`. Tombstone deps continue to be treated as
satisfied for `ready_to_work` computation.

---

## Signal Name

**tombstone file** — a JSON file written by the archiver for each closed ticket that is
archived. The file survives indefinitely after the ticket is archived, providing identity
and type information for any downstream consumer that holds a reference to the archived
ticket ID.

---

## Emitter

**Component**: `plugins/dso/scripts/archive-closed-tickets.sh` # shim-exempt: internal implementation path reference

The emitter writes a tombstone for every ticket it archives. Behavior:

- **Path**: `.tickets-tracker/tombstones/<id>.json` (relative to repo root)
- **Write protocol**: atomic — write to `.tickets-tracker/tombstones/<id>.json.tmp`, then
  `mv` to final path. Partial files are never visible to readers.
- **Idempotency**: if a tombstone already exists at the target path and its `id` field
  matches, the emitter skips the write (does not overwrite). If `id` does not match, this
  is a system integrity error and the emitter must exit non-zero.
- **Directory creation**: the emitter creates `.tickets-tracker/tombstones/` if it does
  not exist (via `mkdir -p`) before writing any tombstone.

---

## Parser

**Component**: `.claude/scripts/dso ticket deps`

The parser reads tombstone files to provide human-readable labels for archived
dependencies. Behavior:

- For each dep ID that is absent from `.tickets-tracker/`, check
  `.tickets-tracker/tombstones/<id>.json`.
- If a tombstone file is present and valid, render the dep as:
  `[archived: <final_status> (<type>)]`
- If no tombstone file is present, fall back to the existing behavior:
  `[missing — treated as satisfied]`
- Tombstone deps are always treated as satisfied for `ready_to_work` computation —
  regardless of the `final_status` value stored in the tombstone.
- On JSON parse error or missing required field, fall back to
  `[missing — treated as satisfied]` and emit a warning to stderr.

### Canonical parsing prefix

The parser MUST match against:

- **tombstone file** — file-path match. A tombstone is identified by its path: `.tickets-tracker/tombstones/<id>.json`. Any file at that path is a candidate tombstone. The parser validates the `id` field against the filename stem and rejects the file if they do not match.

---

## Fields

Tombstone files contain **exactly 3 top-level fields**. No additional fields are allowed.

| Field          | Type   | Constraints                                      |
|----------------|--------|--------------------------------------------------|
| `id`           | string | Ticket ID (e.g. `w20-0aaw`). Must match the filename stem. |
| `type`         | string | One of: `bug`, `epic`, `story`, `task`           |
| `final_status` | string | One of: `closed`                                 |

**Invariants**:

- `id` must equal the filename stem (`<id>.json` → `<id>`). A mismatch is a system
  integrity error; consumers must reject and warn.
- `type` is limited to the four ticket types; no other values are valid.
- `final_status` is always `"closed"` for files written by `archive-closed-tickets.sh`
  (archival only happens when status is closed). The field is retained as an enum rather
  than a boolean to allow future extension without a breaking schema change.

---

## Example

File path: `.tickets-tracker/tombstones/w20-0aaw.json`

```json
{
  "id": "w20-0aaw",
  "type": "task",
  "final_status": "closed"
}
```

`.claude/scripts/dso ticket deps` output for a ticket that depends on `w20-0aaw` after it has been archived:

```
w21-6llo
  └── w20-0aaw [archived: closed (task)]
```

---

## Consumer Story Obligations

| Consumer story | Obligation |
|----------------|-----------|
| w20-p35v (.claude/scripts/dso ticket deps tombstone resolution) | Must read `.tickets-tracker/tombstones/<id>.json` and render `[archived: <final_status> (<type>)]`; fall back to `[missing — treated as satisfied]` on missing file or parse error |
| w20-v9eo (archive-closed-tickets.sh tombstone write) | Must write atomically to `.tmp` then `mv`; must skip if tombstone already exists with matching `id`; must create `tombstones/` dir via `mkdir -p` |
| w20-qxu2 (RED test: tombstone file written on archive) | Must verify that running the archiver produces a valid tombstone at the expected path with all 3 required fields |
