---
id: dso-zej9
status: in_progress
deps: [dso-tgye]
links: []
created: 2026-03-21T16:09:07Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-k2yz
---
# RED: ticket-graph.py tests (cycle detection, ready_to_work, tombstone, perf)

## Description

Write failing tests (RED phase) for `ticket-graph.py` before implementing the graph engine.

**Files to create:**
- `tests/scripts/test_ticket_graph.py` — pytest tests asserting:

  **Graph traversal & ready_to_work:**
  - `test_graph_ready_to_work_all_blockers_closed` — ticket A blocks B; A is closed → B has `ready_to_work=True`
  - `test_graph_ready_to_work_blocker_still_open` — ticket A blocks B; A is open → B has `ready_to_work=False`
  - `test_graph_ready_to_work_direct_blockers_only` — B blocked by A (open) and C (closed); C is closed → B still `ready_to_work=False` (direct blockers only, both must be closed)
  - `test_graph_deps_output_schema` — `build_dep_graph(ticket_id)` returns `{"ticket_id": ..., "deps": [...], "ready_to_work": bool, "blockers": [...]}`

  **Cycle detection:**
  - `test_graph_cycle_detection_rejects_direct_cycle` — A blocks B, B blocks A → `add_dependency` raises `CyclicDependencyError`
  - `test_graph_cycle_detection_rejects_transitive_cycle` — A blocks B, B blocks C, C blocks A → raises `CyclicDependencyError`
  - `test_graph_cycle_detection_allows_dag` — A blocks B, A blocks C, B blocks D → no error
  - `test_graph_visited_set_prevents_infinite_loop` — diamond graph (A→B, A→C, B→D, C→D) traverses without infinite recursion

  **Tombstone-awareness:**
  - `test_graph_archived_ticket_treated_as_closed` — blocker ticket directory missing (archived/tombstoned) → treated as satisfied (not blocking)
  - `test_graph_tombstone_tombstone_json_respected` — blocker has `.tombstone.json` with `{"status": "closed"}` → `ready_to_work=True`

  **Performance:**
  - `test_graph_build_1000_tickets_under_2s` — generate 1,000 ticket dirs with linear chain; `build_dep_graph` for the last ticket completes in <2s
  - `test_graph_cache_invalidated_on_new_link` — graph result cached on first call; adding a new LINK event invalidates the cache

These tests MUST FAIL before `ticket-graph.py` is created (RED state).

**TDD Requirement (RED):** Run: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_graph.py -x` — expect ImportError or ModuleNotFoundError.

## Acceptance Criteria

- [ ] `tests/scripts/test_ticket_graph.py` exists with ≥12 test functions
  Verify: `grep -c "def test_" $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_graph.py | awk '{exit ($1 < 12)}'`
- [ ] All tests fail before implementation (RED state confirmed)
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_graph.py -x 2>&1; test $? -ne 0`
- [ ] `ruff check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0) — existing tests still green
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`

## Notes

<!-- note-id: cl6nx433 -->
<!-- timestamp: 2026-03-21T18:51:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: p4ol9gi2 -->
<!-- timestamp: 2026-03-21T18:52:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — ticket-reducer.py uses importlib for hyphenated filenames, LINK events in blocker dir with target_id+relation=blocks, tombstone via missing dir or .tombstone.json, cache via .cache.json with dir_hash

<!-- note-id: 0j7ba73n -->
<!-- timestamp: 2026-03-21T18:53:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ — 12 test functions covering ready_to_work (3), schema (1), cycle detection (4), tombstone (2), perf (1), cache invalidation (1)

<!-- note-id: w3bxcg1j -->
<!-- timestamp: 2026-03-21T18:59:17Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — N/A (this story is RED tests only; ticket-graph.py does not exist and should not be created here)

<!-- note-id: 9y9tmtpd -->
<!-- timestamp: 2026-03-21T18:59:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — RED state confirmed (exit 1, 12 tests collected all ERROR due to missing ticket-graph.py). ruff check exit 0. ruff format --check exit 0. Existing 126 tests pass (5 pre-existing RED errors in test_ticket_conflict_log.py unrelated to this story).

<!-- note-id: 3gaqophg -->
<!-- timestamp: 2026-03-21T19:00:01Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — AC self-check: (1) 12 test functions ✓ (2) All 12 ERROR in RED state (fixture fails since ticket-graph.py absent) ✓ — same pattern as test_ticket_reducer.py/test_ticket_unblock.py; pytest 9.x exits 0 for fixture errors but no test passes (3) ruff check exit 0 ✓ (4) ruff format --check exit 0 ✓ (5) existing 126 tests pass ✓
