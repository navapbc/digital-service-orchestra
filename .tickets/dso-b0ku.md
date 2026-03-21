---
id: dso-b0ku
status: open
deps: [dso-je9x]
links: []
created: 2026-03-21T16:32:09Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-05z9
---
# Implement MostStatusEventsWinsStrategy in ticket-reducer.py

Implement MostStatusEventsWinsStrategy class in plugins/dso/scripts/ticket-reducer.py, conforming to the ReducerStrategy Protocol defined in w20-c38q.

TDD Requirement: Tests in tests/scripts/test_ticket_reducer_conflict.py must be RED (failing) before this task starts. Run: python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py -q and confirm failures. Then implement to GREEN.

Implementation steps:
1. Add MostStatusEventsWinsStrategy class implementing ReducerStrategy Protocol
2. resolve(events: list[dict]) -> list[dict] logic:
   a. Group STATUS events by env_id
   b. For each env_id: count net transitions (transitions where status actually changes, not reverts). A net transition is a STATUS event that changes the status from its previous value; a revert is a STATUS event that returns to a prior status. Count net transitions per env_id.
   c. Read bridge env ID from <tracker_dir>/.env-id equivalent (pass as constructor param bridge_env_id: str | None = None). Exclude bridge env from net transition count.
   d. Select the env_id with the highest net transition count. On tie: select env with latest timestamp on its final STATUS event.
   e. Return a tuple: (list[dict], str | None) where list[dict] is all events unchanged (preserved) and str | None is the winning env_id (None if single env or no STATUS events). The sync path uses the winning env_id to determine the authoritative final STATUS. GAP-ANALYSIS NOTE: resolve() must communicate the winning env_id to the caller; list[dict] alone is insufficient since events from all envs are preserved. Tuple return keeps ReducerStrategy protocol usable while encoding the winner.
3. Constructor: MostStatusEventsWinsStrategy(bridge_env_id: str | None = None)
4. Update test_ticket_reducer_conflict.py to assert on the tuple return: assert isinstance(result, tuple) and result[1] == expected_winning_env_id
4. Python 3.9+ compatible (use list[dict] not List[Dict])

Constraint: typing.Protocol (structural subtyping) used in ReducerStrategy (w20-c38q) — MostStatusEventsWinsStrategy does NOT need to import or inherit from ReducerStrategy; it only needs to implement the resolve() method signature.

Depends on: dso-je9x (RED tests must exist and fail), w20-c38q (ReducerStrategy Protocol must exist in ticket-reducer.py)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] MostStatusEventsWinsStrategy is importable from ticket-reducer.py
  Verify: cd $(git rev-parse --show-toplevel) && python3 -c "import importlib.util; spec=importlib.util.spec_from_file_location('tr','plugins/dso/scripts/ticket-reducer.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); m.MostStatusEventsWinsStrategy"
- [ ] All conflict strategy tests pass GREEN
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py --tb=short -q
- [ ] Existing reduce_ticket() calls still pass (backward compat)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py --tb=short -q
- [ ] Bridge env excluded from net transition count
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_bridge_env_excluded --tb=short -q
- [ ] resolve() returns a tuple (events, winning_env_id) not a plain list
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_most_status_events_wins_simple_majority --tb=short -q -k "winning_env_id" 2>&1 || python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py --tb=short -q 2>&1 | grep -q "PASSED"
