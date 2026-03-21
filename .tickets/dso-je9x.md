---
id: dso-je9x
status: open
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
