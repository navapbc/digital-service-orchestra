---
id: w21-m5zd
status: open
deps: [w21-4zl2]
links: []
created: 2026-03-22T03:07:54Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2r0x
---
# RED: Write failing tests for per-batch checkpoint with dual-timestamp in bridge-inbound.py

## Description

Write failing unit tests for dual-timestamp checkpoint behavior in bridge-inbound.py.

The dual-timestamp model:
- `last_pull_ts` (main timestamp): advances ONLY after the entire run completes successfully
- `batch_resume_cursor` (per-batch): tracks the last successfully processed batch page; used for resume-only (never advances the pull window)

These tests are RED — they will fail until bridge-inbound.py implements per-batch checkpointing.

**Tests to write in tests/scripts/test_bridge_inbound.py:**

1. `test_last_pull_ts_advances_only_on_full_success` — simulate a run that completes successfully; assert `last_pull_ts` in checkpoint file advances to the new timestamp
2. `test_last_pull_ts_not_advanced_on_mid_run_failure` — simulate a run that fails partway through (exception during processing); assert `last_pull_ts` in checkpoint file is unchanged
3. `test_batch_resume_cursor_written_per_batch` — simulate a paginated run with 3 pages; assert after each page, a `batch_resume_cursor` field is written to the checkpoint file
4. `test_batch_resume_cursor_does_not_advance_last_pull_ts` — verify that writing per-batch cursor does NOT change `last_pull_ts`
5. `test_per_batch_checkpoint_enables_resume` — write a checkpoint with `batch_resume_cursor: 100`; call process_inbound with resume=True; assert pagination starts from page 100, not page 0

**TDD requirement:** All tests must FAIL (RED) before implementation. Confirm red: `python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'batch_checkpoint or batch_resume or last_pull_ts_not_advanced' --tb=line -q`

**File:** tests/scripts/test_bridge_inbound.py (add to existing file)

## Acceptance Criteria

- [ ] All 5 new checkpoint tests exist in tests/scripts/test_bridge_inbound.py
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'batch_checkpoint or batch_resume or last_pull_ts_not_advanced' --collect-only -q 2>&1 | grep -c 'test_' | awk '{exit ($1 < 5)}'
- [ ] All new tests FAIL (RED) before implementation
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'batch_checkpoint or batch_resume or last_pull_ts_not_advanced' --tb=line -q 2>&1 | grep -qE 'FAILED|AttributeError|failed'
- [ ] All pre-existing bridge-inbound tests still pass
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'not (batch_checkpoint or batch_resume or last_pull_ts_not_advanced)' --tb=short -q 2>&1 | grep -q 'passed'
- [ ] ruff format --check passes on the test file
  Verify: ruff format --check tests/scripts/test_bridge_inbound.py
- [ ] ruff check passes on the test file
  Verify: ruff check tests/scripts/test_bridge_inbound.py
