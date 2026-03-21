---
id: dso-tgye
status: open
deps: [dso-vwoo, dso-a4fy]
links: []
created: 2026-03-21T16:09:05Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-k2yz
---
# Extend ticket-reducer.py to handle LINK/UNLINK events

## Description

Extend `plugins/dso/scripts/ticket-reducer.py` to reduce LINK and UNLINK event files into the compiled ticket state's `deps` list.

**Files to modify:**
- `plugins/dso/scripts/ticket-reducer.py`:
  - Initialize `state["deps"]` as `[]` (already present in skeleton; ensure it defaults to `[]`)
  - Add `elif event_type == "LINK":` handler: append `{"target_id": data["target_id"], "relation": data["relation"], "link_uuid": event["uuid"]}` to `state["deps"]`
  - Add `elif event_type == "UNLINK":` handler: remove the dep entry whose `link_uuid` matches `data["link_uuid"]`; if not found, skip silently (no crash)
  - `SNAPSHOT` handler already restores `compiled_state` which will include `deps`; no changes needed there
  - Cache invalidation: LINK/UNLINK events change file count → dir_hash changes → cache miss is automatic (no special handling needed)

**Compaction invariant:** The `deps` list in compiled state is included in SNAPSHOT's `compiled_state` when compaction runs. Since the reducer now populates `deps` from LINK events, the snapshot will capture it. LINK source events are included in `source_event_uuids` so they are skipped on replay — correct.

**TDD Requirement (GREEN):** Make all tests in dso-vwoo pass:
`cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -q`

## Acceptance Criteria

- [ ] `ticket-reducer.py` LINK handler appends to `state["deps"]`
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py::test_reducer_compiles_link_event_into_deps_list -q`
- [ ] `ticket-reducer.py` UNLINK handler removes matching dep by `link_uuid`
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py::test_reducer_unlink_event_removes_dep_entry -q`
- [ ] UNLINK with unknown uuid is a no-op (no crash)
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py::test_reducer_unlink_unknown_uuid_is_noop -q`
- [ ] LINK events survive snapshot/compaction cycle
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py::test_reducer_link_events_survive_snapshot -q`
- [ ] All test_ticket_reducer.py tests pass
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -q`
- [ ] `ruff check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`
