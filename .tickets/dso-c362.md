---
id: dso-c362
status: open
deps: []
links: []
created: 2026-03-21T16:31:54Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-05z9
---
# RED: Write failing tests for ticket-conflict-log.py

Write failing (RED) tests for ticket-conflict-log.py before implementation begins.

File: tests/scripts/test_ticket_conflict_log.py

Tests to write (all must FAIL before Task T4 is implemented):
1. test_conflict_log_records_resolution — writes a conflict resolution record and reads it back; asserts fields: ticket_id, env_ids (list), event_counts (dict), winning_state, timestamp, resolution_method
2. test_conflict_log_format_is_jsonl — log file uses one JSON object per line (JSONL format); multiple records appended correctly
3. test_conflict_log_default_path — log file defaults to <tracker_dir>/conflict-resolutions.jsonl when no path specified
4. test_conflict_log_bridge_env_noted — when bridge env was excluded, log record includes bridge_env_excluded: true field
5. test_conflict_log_write_failure_is_non_fatal — pass a non-writable path as tracker_dir; assert that log_conflict_resolution returns None without raising (GAP-ANALYSIS: write failure must not propagate)

TDD Requirement: Write ALL tests first. Run python3 -m pytest tests/scripts/test_ticket_conflict_log.py -q and confirm ALL fail (RED). Do not implement ticket-conflict-log.py until confirmed RED.

Module: ticket-conflict-log.py must be importable via importlib (hyphenated filename). Main function signature: log_conflict_resolution(tracker_dir, ticket_id, env_ids, event_counts, winning_state, bridge_env_excluded=False) -> None

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/scripts/test_ticket_conflict_log.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_conflict_log.py
- [ ] All 5 test functions are present in test_ticket_conflict_log.py
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_conflict_log.py | awk '{exit ($1 < 5)}'
- [ ] All tests fail RED before T4 implementation
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_conflict_log.py -q 2>&1; test $? -ne 0
