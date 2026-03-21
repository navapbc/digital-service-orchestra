---
id: dso-vtov
status: in_progress
deps: [dso-c362]
links: []
created: 2026-03-21T16:32:17Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-05z9
---
# Implement ticket-conflict-log.py conflict resolution logger

Implement plugins/dso/scripts/ticket-conflict-log.py with log_conflict_resolution() function.

TDD Requirement: Tests in tests/scripts/test_ticket_conflict_log.py must be RED (failing) before this task starts. Run: python3 -m pytest tests/scripts/test_ticket_conflict_log.py -q and confirm failures. Then implement to GREEN.

Implementation steps:
1. Create plugins/dso/scripts/ticket-conflict-log.py
2. Function signature: log_conflict_resolution(tracker_dir: str, ticket_id: str, env_ids: list[str], event_counts: dict[str, int], winning_state: str, bridge_env_excluded: bool = False) -> None
3. Log file location: <tracker_dir>/conflict-resolutions.jsonl (append mode)
4. Each record is a JSON object on a single line (JSONL format):
   {timestamp: <epoch int>, ticket_id: <str>, env_ids: [<str>,...], event_counts: {<env_id>: <int>,...}, winning_state: <str>, resolution_method: 'most-status-events-wins', bridge_env_excluded: <bool>}
5. Atomic append: open in 'a' mode, write single json line, flush
6. Error handling (GAP-ANALYSIS): wrap file I/O in try/except OSError; on failure print a WARNING to stderr and return without raising. A conflict log write failure must NOT propagate to the caller — the sync operation must continue even if the log cannot be written.
7. Module interface: importable via importlib (hyphenated filename) as log_conflict_resolution

Depends on: dso-c362 (RED tests must exist and fail)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ticket-conflict-log.py exists at correct path
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-conflict-log.py
- [ ] log_conflict_resolution importable via importlib
  Verify: cd $(git rev-parse --show-toplevel) && python3 -c "import importlib.util; spec=importlib.util.spec_from_file_location('tcl','plugins/dso/scripts/ticket-conflict-log.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); m.log_conflict_resolution"
- [ ] All conflict log tests pass GREEN
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_conflict_log.py --tb=short -q
- [ ] Log file uses JSONL format (one JSON object per line)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_conflict_log.py::test_conflict_log_format_is_jsonl --tb=short -q
- [ ] Write failure degrades gracefully (no exception propagated when log dir unwritable)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_conflict_log.py::test_conflict_log_write_failure_is_non_fatal --tb=short -q

## Notes

<!-- note-id: t5qgbhiz -->
<!-- timestamp: 2026-03-21T19:12:57Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: acdtamsv -->
<!-- timestamp: 2026-03-21T19:13:11Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 7f97xhfi -->
<!-- timestamp: 2026-03-21T19:13:17Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ (5 RED tests exist in test_ticket_conflict_log.py)

<!-- note-id: 3w4qy343 -->
<!-- timestamp: 2026-03-21T19:13:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: vxgtuhwf -->
<!-- timestamp: 2026-03-21T19:13:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ (5/5 tests GREEN)

<!-- note-id: 84fkxwwf -->
<!-- timestamp: 2026-03-21T19:13:53Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All AC verified: file exists, importlib callable, 5/5 tests GREEN, ruff check PASS, ruff format PASS, JSONL format test PASS, write-failure non-fatal test PASS
