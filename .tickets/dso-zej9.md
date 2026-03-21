---
id: dso-zej9
status: open
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
