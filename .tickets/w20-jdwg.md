---
id: w20-jdwg
status: closed
deps: [w20-kkp5]
links: []
created: 2026-03-21T16:23:03Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-6k7v
---
# RED: tests for ReducerStrategy protocol and LastTimestampWinsStrategy

Write failing tests FIRST in tests/scripts/test_ticket_reducer_strategy.py. All tests must FAIL (RED) before T2 (implementation) begins.

Tests to write:
- test_last_timestamp_wins_strategy_is_importable: from ticket_reducer import LastTimestampWinsStrategy (fails because class does not exist yet)
- test_last_timestamp_wins_dedup_by_uuid: merge two event lists with one overlapping UUID; result contains that UUID exactly once
- test_last_timestamp_wins_sorted_by_timestamp: events from both lists appear in ascending timestamp order in merged result
- test_reducer_strategy_protocol_has_resolve_method: ReducerStrategy Protocol has resolve(events: list[dict]) -> list[dict] signature
- test_default_reducer_used_when_no_strategy_provided: reduce_ticket(path) (no strategy arg) uses LastTimestampWinsStrategy behavior (dedup + sort)

Use importlib pattern (same as test_ticket_reducer.py) to load ticket-reducer.py by path since filename has hyphens.

Run to verify RED: cd $(git rev-parse --show-toplevel) && poetry run pytest tests/scripts/test_ticket_reducer_strategy.py --tb=short -q

Depends on: w20-kkp5 (contract must exist first — defines the interface shape)


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file exists at correct path
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer_strategy.py
- [ ] Test file contains 5 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer_strategy.py | awk '{exit ($1 < 5)}'
- [ ] Tests are RED before T2 implementation (all fail against current ticket-reducer.py)
  Verify: cd $(git rev-parse --show-toplevel) && poetry run pytest tests/scripts/test_ticket_reducer_strategy.py --tb=no -q 2>&1; [ $? -ne 0 ]
- [ ] ruff finds no issues in the new test file
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/scripts/test_ticket_reducer_strategy.py

## Notes

<!-- note-id: 7ukn4pbp -->
<!-- timestamp: 2026-03-21T16:57:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: jiwonwev -->
<!-- timestamp: 2026-03-21T16:58:19Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 9r5rj00w -->
<!-- timestamp: 2026-03-21T17:01:08Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: 00acw1ia -->
<!-- timestamp: 2026-03-21T17:01:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ (RED task — no implementation; tests intentionally fail)

<!-- note-id: w4f8wk1m -->
<!-- timestamp: 2026-03-21T17:01:46Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: o68k7ed2 -->
<!-- timestamp: 2026-03-21T17:20:35Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
