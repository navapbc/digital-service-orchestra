---
id: dso-3npm
status: open
deps: [dso-24cw]
links: []
created: 2026-03-21T16:19:22Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-8011
---
# Implement ticket-unblock.py with detect_newly_unblocked and batch graph traversal

Implement plugins/dso/scripts/ticket-unblock.py exposing detect_newly_unblocked(). Make tests/scripts/test_ticket_unblock.py pass (GREEN).

Implementation requirements:
1. Function signature: detect_newly_unblocked(closed_ticket_ids: list[str], tracker_dir: str, event_source: str) -> list[str]
2. event_source parameter: accepts 'local-close' or 'sync-resolution' (validated, raises ValueError for other values)
3. Batch graph traversal: import the graph traversal function from ticket-graph.py (w21-k2yz) via importlib (hyphenated filename). IMPORTANT: before implementing, read ticket-graph.py to determine the actual exported function name and signature -- do not assume 'get_ready_tickets()'. Adapt to whatever interface ticket-graph.py exposes. Call graph traversal ONCE for all closed_ticket_ids rather than once per ticket -- satisfies burst-scenario performance requirement from adversarial review.
4. Algorithm: given closed_ticket_ids, query all tickets whose ready_to_work flips to True after those tickets are closed. Pass closed_ticket_ids as 'override_statuses' (or equivalent parameter) to ticket-graph.py's traversal so it treats them as closed without writing new events.
5. Returns: list of ticket IDs (strings) that are newly unblocked. Returns empty list if none.
6. CLI entry point: ticket-unblock.py <tracker_dir> <ticket_id> [--event-source local-close|sync-resolution] for use from bash scripts
7. Module interface: importable as detect_newly_unblocked for use from Python

File: plugins/dso/scripts/ticket-unblock.py

TDD Requirement: Tests in tests/scripts/test_ticket_unblock.py must be RED (failing) before this task starts. Run: python3 -m pytest tests/scripts/test_ticket_unblock.py -q and confirm failures. Then implement to GREEN.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-unblock.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-unblock.py
- [ ] plugins/dso/scripts/ticket-unblock.py exists and is executable
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-unblock.py
- [ ] detect_newly_unblocked function is importable via importlib
  Verify: cd $(git rev-parse --show-toplevel) && python3 -c "import importlib.util; spec=importlib.util.spec_from_file_location('ticket_unblock','plugins/dso/scripts/ticket-unblock.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); assert hasattr(m,'detect_newly_unblocked')"
- [ ] All 5 tests in test_ticket_unblock.py pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_unblock.py -q
- [ ] Function accepts event_source='local-close' and 'sync-resolution' without error
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_unblock.py::test_event_source_parameter_accepted -v
- [ ] CLI entry point: ticket-unblock.py exits non-zero with usage message when called without arguments
  Verify: { python3 $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-unblock.py 2>/dev/null; test $? -ne 0; }

