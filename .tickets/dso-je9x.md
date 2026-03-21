---
id: dso-je9x
status: in_progress
deps: []
links: []
created: 2026-03-21T16:31:44Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-05z9
---
# RED: Write failing tests for MostStatusEventsWinsStrategy

Write failing (RED) tests for MostStatusEventsWinsStrategy before implementation begins.

File: tests/scripts/test_ticket_reducer_conflict.py

Tests to write (all must FAIL before Task T3 is implemented):
1. test_most_status_events_wins_simple_majority — two envs, env-A has 3 net STATUS transitions, env-B has 1; env-A latest STATUS wins
2. test_net_transitions_not_raw_events — env with 5 raw STATUS events but 1 net transition loses to env with 2 net transitions
3. test_timestamp_tiebreaker — two envs equal net transitions; latest timestamp wins
4. test_bridge_env_excluded — bridge env ID excluded from count; non-bridge env wins even with fewer raw events
5. test_single_env_no_conflict — single env; no conflict, returns latest STATUS unchanged

TDD Requirement: Write ALL tests first. Run python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py -q and confirm ALL fail (RED).

Depends on: w20-kkp5 (contract must exist)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/scripts/test_ticket_reducer_conflict.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer_conflict.py
- [ ] All 5 test functions are present in test_ticket_reducer_conflict.py
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer_conflict.py | awk '{exit ($1 < 5)}'
- [ ] All tests fail RED before T3 implementation
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py -q 2>&1; test $? -ne 0

## Notes

**2026-03-21T19:12:54Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T19:13:12Z**

CHECKPOINT 2/6: Code patterns understood ✓ — ReducerStrategy Protocol, LastTimestampWinsStrategy, reduce_ticket() in ticket-reducer.py; contract at ticket-reducer-strategy-contract.md; existing test pattern uses importlib to load hyphenated module

**2026-03-21T19:14:17Z**

CHECKPOINT 3/6: Tests written ✓ — 5 test functions in tests/scripts/test_ticket_reducer_conflict.py covering: simple majority, net vs raw events, timestamp tiebreaker, bridge env exclusion, single env no conflict

**2026-03-21T19:19:36Z**

CHECKPOINT 4/6: Implementation complete ✓ — tests/scripts/test_ticket_reducer_conflict.py created with 5 RED tests; all fail with AssertionError: MostStatusEventsWinsStrategy not found

**2026-03-21T19:20:02Z**

CHECKPOINT 5/6: Validation passed ✓ — 5 failed (RED), exit 1; ruff check exit 0; ruff format --check exit 0; 145 existing tests unaffected

**2026-03-21T19:20:08Z**

CHECKPOINT 6/6: Done ✓ — All 6 ACs verified: file exists, 5 tests present, all RED (exit 1), ruff check pass, ruff format pass, run-all.sh overall PASS
