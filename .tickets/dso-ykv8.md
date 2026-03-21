---
id: dso-ykv8
status: closed
deps: [dso-ljbc]
links: []
created: 2026-03-21T06:50:31Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-f8tg
---
# PERF: Write warm-cache performance benchmark tests (200 and 1,000 tickets)

Write warm-cache performance benchmark tests validating the story's performance done definitions. These tests run after Task dso-ljbc (IMPL) is complete — the cache must exist for warm-cache timing targets to be achievable.

## TDD Requirement

Integration Test Task — written after implementation per SKILL.md integration exemption: 'For tasks that cross an external boundary (file system), the integration test task does not require a RED-first dependency — it may be written after the implementation task.'

This task crosses a file-system boundary: it creates 200 and 1,000 real ticket directories on disk and measures actual I/O timing. Integration exemption criterion applies.

## Tests to Write

Append 2 tests to tests/scripts/test_ticket_reducer.py:

### test_warm_cache_200_tickets_under_500ms

Setup:
- Create 200 ticket directories in tmp_path, each with a CREATE event file
- Call reduce_ticket() on each to warm the cache (first pass, cache miss — OK to be slow)
- Time the second pass: call reduce_ticket() on all 200 again and measure total time

Assert:
- Total elapsed for 200 warm-cache calls < 0.5 seconds (500ms)
- Use time.monotonic() for measurement

### test_warm_cache_1000_tickets_under_2s

Setup:
- Create 1,000 ticket directories in tmp_path, each with a CREATE event file
- Call reduce_ticket() on each to warm the cache (first pass)
- Time the second pass over all 1,000

Assert:
- Total elapsed for 1,000 warm-cache calls < 2.0 seconds
- Use time.monotonic() for measurement

## Mark these tests

Add @pytest.mark.unit and @pytest.mark.scripts decorators. The 1,000-ticket test is expected to be the slowest unit test in the suite but should complete in < 10 seconds for CI.

## File Impact

- tests/scripts/test_ticket_reducer.py: Edit (append 2 performance test functions)

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` exits 0 (all tests pass including 2 new performance tests)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/scripts/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/scripts/*.py
- [ ] test_warm_cache_200_tickets_under_500ms function exists and passes
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py::test_warm_cache_200_tickets_under_500ms --tb=short -q
- [ ] test_warm_cache_1000_tickets_under_2s function exists and passes
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py::test_warm_cache_1000_tickets_under_2s --tb=short -q
- [ ] 200-ticket warm-cache pass completes in under 500ms
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py::test_warm_cache_200_tickets_under_500ms --tb=short 2>&1 | grep -qv FAILED
- [ ] 1000-ticket warm-cache pass completes in under 2 seconds
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py::test_warm_cache_1000_tickets_under_2s --tb=short 2>&1 | grep -qv FAILED


## Notes

**2026-03-21T06:59:16Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T07:00:08Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T07:06:09Z**

CHECKPOINT 6/6: Done ✓ — Benchmark tests added. 200/1000 tickets pass.
