---
id: dso-dr38
status: open
deps: [dso-zej9]
links: []
created: 2026-03-21T16:09:11Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-k2yz
---
# Implement ticket-graph.py (graph traversal, cycle detection, ready_to_work, cache)

## Description

Implement `plugins/dso/scripts/ticket-graph.py` — the graph engine for dependency traversal, cycle detection, ready_to_work computation, and graph cache.

**Files to create:**
- `plugins/dso/scripts/ticket-graph.py` — new Python module exposing:

  **Public API:**
  - `build_dep_graph(ticket_id: str, tickets_dir: str) -> dict` — returns `{"ticket_id": str, "deps": list[dict], "blockers": list[str], "ready_to_work": bool}`
  - `check_would_create_cycle(source_id: str, target_id: str, relation: str, tickets_dir: str) -> bool` — returns True if adding source→target would create a cycle (only `blocks`/`depends_on` edges; `relates_to` never creates cycles)
  - `CyclicDependencyError(Exception)` — raised by `check_would_create_cycle` when cycle detected
  - `add_dependency(source_id, target_id, relation, tickets_dir)` — calls `check_would_create_cycle` then writes LINK event by invoking `ticket-link.sh` as a subprocess (or replicating its event-writing logic in Python); raises `CyclicDependencyError` before writing if cycle would result. **This is the authoritative write path for `ticket link` CLI** — dso-jefv routes `ticket link` through this function for cycle-checked linking.
  - **CLI flags**: `python3 ticket-graph.py <ticket_id>` (deps query) AND `python3 ticket-graph.py --link <source> <target> <relation>` (add dependency with cycle check, used by `ticket link` CLI after dso-jefv updates the dispatcher)

  **Graph traversal algorithm:**
  - Read compiled state for each ticket via `ticket-reducer.py`'s `reduce_ticket()` (import via importlib for hyphenated filename)
  - Traverse `deps` list from compiled state; only `blocks` and `depends_on` relations are blocking (contribute to `ready_to_work`); `relates_to` is informational only
  - Use a `visited` set to prevent infinite loops in diamond-shaped or re-entrant graphs
  - Direct blockers only for `ready_to_work`: a ticket is ready when all direct `blocks`/`depends_on` blockers have `status=closed`

  **Tombstone-awareness:**
  - If a blocker ticket directory does not exist in `.tickets-tracker/`, treat it as closed (tombstoned)
  - If `.tickets-tracker/<id>/.tombstone.json` exists, read `status` field; treat as that status
  - If directory exists but `reduce_ticket()` returns `None`, treat as closed (ghost ticket safety)

  **Graph cache:**
  - Cache file: `.tickets-tracker/.graph-cache.json`
  - Key: sha256 of all ticket dirs' content hashes (same method as reducer's `dir_hash`)
  - On hit: return cached graph for ticket_id
  - On miss: compute graph, write cache atomically (tmp + rename), return result
  - Cache must be invalidated when any LINK/UNLINK event is added (new file → dir_hash changes → graph cache key changes)

  **Performance target:** `build_dep_graph` for any ticket in a 1,000-ticket store completes in <2s

  **CLI entry point:** `python3 ticket-graph.py <ticket_id> [--tickets-dir=<path>]` — prints JSON output of `build_dep_graph`

**TDD Requirement (GREEN):** Make all tests in dso-zej9 pass:
`cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_graph.py -q`

## Acceptance Criteria

- [ ] `plugins/dso/scripts/ticket-graph.py` exists and is executable
  Verify: `test -f $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-graph.py`
- [ ] `build_dep_graph` returns correct `ready_to_work=True` when all direct blockers are closed
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_graph.py::test_graph_ready_to_work_all_blockers_closed -q`
- [ ] Cycle detection raises `CyclicDependencyError` for direct and transitive cycles
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_graph.py -k "cycle" -q`
- [ ] Tombstone-aware: missing blocker dir treated as closed
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_graph.py -k "tombstone" -q`
- [ ] 1,000-ticket linear chain traversal completes in <2s
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_graph.py::test_graph_build_1000_tickets_under_2s -q`
- [ ] Graph cache invalidated on new LINK event
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_graph.py::test_graph_cache_invalidated_on_new_link -q`
- [ ] All test_ticket_graph.py tests pass
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_graph.py -q`
- [ ] `ruff check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`
