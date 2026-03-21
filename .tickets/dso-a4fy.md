---
id: dso-a4fy
status: in_progress
deps: [dso-2igj]
links: []
created: 2026-03-21T16:09:01Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-k2yz
---
# Implement ticket-link.sh (LINK/UNLINK event writing)

## Description

Implement `plugins/dso/scripts/ticket-link.sh` — the backend for `ticket link` and `ticket unlink` subcommands. This script writes LINK and UNLINK event files to `.tickets-tracker/<ticket-id>/` following the event file naming convention from `plugins/dso/docs/contracts/ticket-event-format.md`.

**Files to create/modify:**
- `plugins/dso/scripts/ticket-link.sh` — new script handling:
  - `ticket link <id1> <id2> <relation>` — writes `<timestamp>-<uuid>-LINK.json` to `.tickets-tracker/<id1>/`; for `relates_to`, also writes a reciprocal LINK event to `.tickets-tracker/<id2>/`
  - `ticket unlink <id1> <id2>` — writes `<timestamp>-<uuid>-UNLINK.json` to `.tickets-tracker/<id1>/` with `data.link_uuid` referencing the original LINK event uuid
  - Idempotency: before writing, scan existing LINK events for same (target_id, relation) pair; skip if found
  - Relations supported: `blocks`, `depends_on`, `relates_to`
  - Validates both ticket IDs exist (ticket dirs present); exits nonzero if not
- `plugins/dso/scripts/ticket` — add `link` and `unlink` dispatch cases routing to `ticket-link.sh`

**LINK event data schema** (per contract):
```json
{
  "event_type": "LINK",
  "timestamp": <int>,
  "uuid": "<uuid4>",
  "env_id": "<uuid4>",
  "author": "<git user.name>",
  "data": {
    "relation": "blocks|depends_on|relates_to",
    "target_id": "<ticket-id>"
  }
}
```

**UNLINK event data schema:**
```json
{
  "event_type": "UNLINK",
  "timestamp": <int>,
  "uuid": "<uuid4>",
  "env_id": "<uuid4>",
  "author": "<git user.name>",
  "data": {
    "link_uuid": "<uuid of original LINK event>",
    "target_id": "<ticket-id>"
  }
}
```

**LINK event compaction note:** LINK events must survive compaction — the SNAPSHOT event's `compiled_state` must include the compiled `deps` list (after ticket-reducer.py handles LINK events). This is guaranteed by the reducer task (dso-tgye) which adds `deps` to compiled state.

**Cycle detection deferral:** ticket-link.sh does NOT implement cycle detection. Cycle detection is added in dso-dr38 (ticket-graph.py's `add_dependency()` function). After dso-jefv, the `ticket link` CLI command routes through ticket-graph.py which performs cycle checking BEFORE calling the event-write logic. ticket-link.sh is the low-level event writer; the public-facing safe path is ticket-graph.py's `add_dependency()`.

**TDD Requirement (GREEN):** Make `bash tests/scripts/test-ticket-link.sh` pass (exit 0). All tests written in dso-2igj must go GREEN after this task.

## Acceptance Criteria

- [ ] `plugins/dso/scripts/ticket-link.sh` exists and is executable
  Verify: `test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-link.sh`
- [ ] `ticket link <id1> <id2> blocks` creates a LINK event file in `.tickets-tracker/<id1>/` with correct schema
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-link.sh`
- [ ] `ticket unlink <id1> <id2>` creates an UNLINK event file with `data.link_uuid` pointing to the LINK event
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-link.sh`
- [ ] `ticket` dispatcher routes `link` and `unlink` to `ticket-link.sh`
  Verify: `grep -q "link" $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket`
- [ ] Duplicate link call is idempotent — no second LINK event written
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-link.sh`
- [ ] `ruff check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`

## Notes

**2026-03-21T17:33:48Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T17:34:30Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T17:35:51Z**

CHECKPOINT 3/6: Tests written ✓ (RED tests existed from dso-2igj)

**2026-03-21T17:35:53Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T17:36:15Z**

CHECKPOINT 5/6: Validation passed ✓ — 22 assertions, 0 failures

**2026-03-21T17:38:52Z**

CHECKPOINT 6/6: Done ✓ — All AC verified: ticket-link.sh executable, all 7 tests pass (22 assertions), link/unlink wired in dispatcher, ruff check/format pass, run-all.sh 55/55 pass
