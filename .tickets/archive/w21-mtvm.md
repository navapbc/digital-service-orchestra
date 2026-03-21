---
id: w21-mtvm
status: closed
deps: []
links: []
created: 2026-03-21T00:51:23Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ablv
---
# Contract: event file format and reducer ordering interface


## Description

Define the cross-story contract for event file naming convention, directory layout, and reducer ordering guarantee.

**Location to create**: plugins/dso/docs/contracts/ticket-event-format.md

### Event file naming convention
`.tickets-tracker/<ticket-id>/<timestamp>-<uuid>-<TYPE>.json`
- `<timestamp>`: UTC epoch seconds (integer), zero-padded to 10 digits for sort correctness
- `<uuid>`: lowercase UUID4 (hyphens preserved in filename and JSON payload)
- `<TYPE>`: one of CREATE, STATUS, COMMENT, LINK, SNAPSHOT, SYNC (uppercase)

### Directory layout
```
.tickets-tracker/
  <ticket-id>/
    <timestamp>-<uuid>-<TYPE>.json   (event files, committed to tickets branch)
    .state-cache                      (compiled-state cache, gitignored on tickets branch)
  .env-id                             (UUID4 environment identity, gitignored on tickets branch)
```

### JSON event base schema
All events share:
- `timestamp`: integer UTC epoch seconds
- `uuid`: UUID4 string
- `event_type`: one of CREATE | STATUS | COMMENT | LINK | SNAPSHOT | SYNC
- `env_id`: UUID4 string from `.tickets-tracker/.env-id`
- `author`: git user.name string
- `data`: object with type-specific fields

CREATE data fields: `{ "ticket_type": "<bug|epic|story|task>", "title": "<string>", "parent_id": <string|null> }`

### Reducer ordering guarantee
Events are sorted by filename (lexicographic sort) before reduction. Since filenames are
prefixed with zero-padded UTC epoch timestamps, this guarantees chronological ordering.
Tie-breaking for same-second events uses the UUID component (lexicographic).
This ordering is deterministic and reproducible across environments.

## TDD Requirement
test-exempt: static assets only — no conditional logic, no executable code. This task creates
a contract document only. Exemption criterion: "static assets only — no executable assertion is possible."

## Acceptance Criteria
- [ ] Contract document exists at `plugins/dso/docs/contracts/ticket-event-format.md`
  Verify: `test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md`
- [ ] Contract defines the event file naming pattern (timestamp-uuid-TYPE.json)
  Verify: `grep -q 'timestamp.*uuid.*TYPE\|TYPE.*uuid.*timestamp' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md`
- [ ] Contract defines the reducer ordering guarantee (filename sort = chronological order)
  Verify: `grep -q 'reducer\|ordering\|sort' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md`
- [ ] Contract defines all required event_type base fields (timestamp, uuid, event_type, env_id, author, data)
  Verify: `grep -q 'env_id\|event_type' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md`

## Notes

**2026-03-21T01:02:11Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T01:02:22Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T01:02:25Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-21T01:03:00Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T01:03:06Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T01:03:14Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T01:16:11Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/docs/contracts/ticket-event-format.md. Tests: N/A (contract doc).
