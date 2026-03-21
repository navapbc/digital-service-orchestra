---
id: dso-6b5d
status: closed
deps: []
links: []
created: 2026-03-21T06:49:44Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-f8tg
---
# RED: Write failing cache tests for ticket-reducer (hit, miss, file-deletion invalidation)

Write failing unit tests for the compiled-state cache feature to be added to ticket-reducer.py. All tests must fail RED before Task 2 is implemented.

## TDD Requirement

Write the following 3 failing tests in tests/scripts/test_ticket_reducer.py (append to existing test file after the existing 11 tests):

1. test_cache_hit_returns_cached_state
   - Setup: write a CREATE event in tmp_path/tkt-cache-hit/, call reduce_ticket() once (warms cache, populates .cache.json), call reduce_ticket() again WITHOUT modifying any files
   - Assert: second call returns the same state as first (cache hit — same dir_hash → serve from .cache.json)
   - Also assert: .cache.json exists in the ticket directory after the first call
   - Verify RED: before caching is implemented, reduce_ticket() reads events on every call (no .cache.json written) — assert .cache.json exists will fail RED
   - NOTE: Do NOT delete the event file between calls in this test — deleting changes the dir_hash and triggers a cache miss + recompute (that scenario is test 3). This test isolates the pure "no-change = cache hit" path.

2. test_cache_miss_on_directory_listing_change
   - Setup: write a CREATE event in tmp_path/tkt-cache-miss/, call reduce_ticket() once (warms cache), write a STATUS event file, call reduce_ticket() again
   - Assert: second call returns updated state reflecting STATUS event (cache miss detected, recomputed)
   - Verify RED: no cache to invalidate yet, so this test structure is ready for green once cache is added

3. test_cache_invalidated_on_file_deletion
   - Setup: write CREATE + STATUS + COMMENT events, call reduce_ticket() (warm cache), delete COMMENT file, call reduce_ticket() again
   - Assert: second call state has 0 comments (deletion detected, cache invalidated, state recomputed)
   - Critical for w21-q0nn compaction: cache must detect file DELETIONS, not just additions
   - Verify RED: without caching, second call already sees correct state (0 comments) — but the test asserts that the cache was correctly INVALIDATED, not just that the state is correct. Design the test to also assert the cache file is updated after recompute.

## Implementation Notes

- Use the same importlib pattern and _write_event() helper as the existing 11 tests
- Use @pytest.mark.unit and @pytest.mark.scripts decorators
- Do NOT implement any cache logic — test writing only

## File Impact

- tests/scripts/test_ticket_reducer.py: Edit (append 3 new test functions)

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` exits non-zero for at least the 3 new cache tests (RED)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py -k 'cache' --tb=no -q 2>&1 | grep -q 'failed'
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/scripts/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/scripts/*.py
- [ ] test_cache_hit_returns_cached_state function exists in test file
  Verify: grep -q 'def test_cache_hit_returns_cached_state' $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py
- [ ] test_cache_miss_on_directory_listing_change function exists in test file
  Verify: grep -q 'def test_cache_miss_on_directory_listing_change' $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py
- [ ] test_cache_invalidated_on_file_deletion function exists in test file
  Verify: grep -q 'def test_cache_invalidated_on_file_deletion' $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py
- [ ] All 3 new tests fail against current ticket-reducer.py (confirms RED)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py -k 'cache_hit or cache_miss or cache_invalidated' --tb=no -q 2>&1 | grep -qE 'failed|error'


## Notes

<!-- note-id: az1lgxlk -->
<!-- timestamp: 2026-03-21T06:54:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 83a21t4g -->
<!-- timestamp: 2026-03-21T06:54:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 242wacxn -->
<!-- timestamp: 2026-03-21T06:55:19Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: ubhueg1w -->
<!-- timestamp: 2026-03-21T06:55:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete (RED test only) ✓

<!-- note-id: l5urkkym -->
<!-- timestamp: 2026-03-21T06:55:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

**2026-03-21T06:57:38Z**

CHECKPOINT 6/6: Done ✓ — 3 RED cache tests added. 3 failed, 11 passed.
