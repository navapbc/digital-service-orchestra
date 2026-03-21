---
id: dso-1a6u
status: open
deps: [dso-b0ku, dso-vtov]
links: []
created: 2026-03-21T16:32:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-05z9
---
# Hook MostStatusEventsWinsStrategy into _sync_events in tk

Wire MostStatusEventsWinsStrategy into the _sync_events split-phase sync function in plugins/dso/scripts/tk (implemented by w20-rpdy).

TDD Requirement: This task modifies behavioral content (conditionally applying conflict resolution strategy). Write a RED test first.
Test file: tests/scripts/test_ticket_reducer_conflict.py
Test to add: test_sync_uses_most_status_events_wins_strategy — simulates two local event sets for same ticket from different envs, calls resolve() on merged event list, verifies that the winning env's final STATUS is correctly identified.
Run: python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_sync_uses_most_status_events_wins_strategy -q and confirm failure before implementation.

Implementation steps:
1. Read bridge_env_id from <tracker_dir>/.env-id (or equivalent config location used by tk)
2. After rebase phase in _sync_events: for each ticket with events from multiple env_ids, instantiate MostStatusEventsWinsStrategy(bridge_env_id=bridge_env_id)
3. Call strategy.resolve(ticket_events) to get authoritative env_id
4. Apply winning state to compiled ticket state (do NOT filter events — all events preserved)
5. Pass conflict data to log_conflict_resolution() from ticket-conflict-log.py
6. Import MostStatusEventsWinsStrategy and log_conflict_resolution via importlib (hyphenated filenames)

Constraint: Strategy is only invoked when events from 2+ distinct env_ids exist for the same ticket (single-env tickets skip resolution).
Constraint: All original events are preserved regardless of conflict resolution outcome.

Depends on: dso-b0ku (MostStatusEventsWinsStrategy must exist), dso-vtov (log_conflict_resolution must exist), w20-rpdy (_sync_events must exist in tk)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Strategy integration test passes GREEN
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_sync_uses_most_status_events_wins_strategy --tb=short -q
- [ ] Single-env tickets skip strategy (no conflict triggered)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_single_env_no_conflict --tb=short -q
- [ ] conflict-resolutions.jsonl written for multi-env conflict
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer_conflict.py::test_sync_writes_conflict_log --tb=short -q

