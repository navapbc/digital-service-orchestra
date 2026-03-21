---
id: dso-24cw
status: open
deps: []
links: []
created: 2026-03-21T16:19:10Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-8011
---
# RED: Write failing tests for ticket-unblock.py detect_newly_unblocked function

Write failing tests in tests/scripts/test_ticket_unblock.py for the detect_newly_unblocked function before implementing ticket-unblock.py.

TDD Requirement (RED): Write these tests FIRST -- all must FAIL before ticket-unblock.py exists:
- test_no_newly_unblocked_when_blocked_by_other_ticket: closing ticket A does not unblock B when B also depends on C (still open)
- test_single_newly_unblocked_on_close: closing ticket A unblocks B when B's only blocker was A
- test_multiple_newly_unblocked_on_close: closing ticket A unblocks B and C simultaneously
- test_batch_graph_query_for_burst: detect_newly_unblocked accepts a list of closed_ticket_ids and calls graph traversal once (not per-ticket)
- test_event_source_parameter_accepted: function accepts event_source parameter with values 'local-close' and 'sync-resolution'

File to create: tests/scripts/test_ticket_unblock.py

Function signature to test (does not exist yet):
  detect_newly_unblocked(closed_ticket_ids: list[str], tracker_dir: str, event_source: str) -> list[str]
  Returns list of ticket IDs that are now ready_to_work=True after the given tickets are closed.

This task has no implementation dependency -- it tests behavior that does not yet exist.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/scripts/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/scripts/*.py
- [ ] tests/scripts/test_ticket_unblock.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_unblock.py
- [ ] Test file contains at least 5 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_unblock.py | awk '{exit ($1 < 5)}'
- [ ] All 5 named test functions are present: test_no_newly_unblocked_when_blocked_by_other_ticket, test_single_newly_unblocked_on_close, test_multiple_newly_unblocked_on_close, test_batch_graph_query_for_burst, test_event_source_parameter_accepted
  Verify: for t in test_no_newly_unblocked_when_blocked_by_other_ticket test_single_newly_unblocked_on_close test_multiple_newly_unblocked_on_close test_batch_graph_query_for_burst test_event_source_parameter_accepted; do grep -q "def $t" $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_unblock.py || { echo "MISSING: $t"; exit 1; }; done
- [ ] All tests FAIL before ticket-unblock.py is implemented (RED state confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_unblock.py -q 2>&1 | grep -qE 'ERROR|FAILED|ImportError|ModuleNotFoundError'

