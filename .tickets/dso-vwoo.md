---
id: dso-vwoo
status: in_progress
deps: []
links: []
created: 2026-03-21T16:09:02Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-k2yz
---
# RED: LINK event reduction tests in test_ticket_reducer.py

## Description

Write failing tests (RED phase) for LINK/UNLINK event handling in `ticket-reducer.py` before extending the reducer.

**Files to modify:**
- `tests/scripts/test_ticket_reducer.py` — add new test functions:
  - `test_reducer_compiles_link_event_into_deps_list` — LINK event with `data.relation=blocks`, `data.target_id=tkt-002` results in `state["deps"] == [{"target_id": "tkt-002", "relation": "blocks", "link_uuid": "<uuid>"}]`
  - `test_reducer_compiles_multiple_link_events` — two LINK events produce two entries in `state["deps"]`
  - `test_reducer_unlink_event_removes_dep_entry` — a LINK event followed by a UNLINK event (with matching `link_uuid`) results in the dep entry being removed from `state["deps"]`
  - `test_reducer_unlink_unknown_uuid_is_noop` — UNLINK with unknown `link_uuid` does not crash; `state["deps"]` unchanged
  - `test_reducer_link_events_survive_snapshot` — LINK event before SNAPSHOT, then one more LINK after; compiled state has both deps (snapshot captures deps list, post-snapshot LINK appends)
  - `test_reducer_deps_in_snapshot_not_duplicated` — LINK event included in SNAPSHOT's `source_event_uuids` is not double-counted

These tests MUST FAIL before ticket-reducer.py is extended to handle LINK/UNLINK (RED state).

**TDD Requirement (RED):** Run: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py::test_reducer_compiles_link_event_into_deps_list -x` — expect failure (AttributeError or assertion failure).

## Acceptance Criteria

- [ ] New test functions added to `tests/scripts/test_ticket_reducer.py`
  Verify: `grep -c "def test_reducer.*link\|def test_reducer.*dep\|def test_reducer.*unlink" $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py | awk '{exit ($1 < 6)}'`
- [ ] All new tests fail before implementation (RED state confirmed)
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py::test_reducer_compiles_link_event_into_deps_list -x 2>&1; test $? -ne 0`
- [ ] Existing tests in test_ticket_reducer.py still pass
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -k "not link and not unlink and not dep" -q`
- [ ] `ruff check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`

## Notes

**2026-03-21T16:58:05Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T16:58:26Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T16:59:11Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T17:00:59Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T17:01:32Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T17:02:12Z**

CHECKPOINT 6/6: Done ✓
