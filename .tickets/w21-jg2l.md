---
id: w21-jg2l
status: in_progress
deps: [w21-m5zd, w21-4zl2]
links: []
created: 2026-03-22T03:07:57Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2r0x
---
# Implement per-batch checkpoint with dual-timestamp in bridge-inbound.py

## Description

Implement dual-timestamp checkpoint in `plugins/dso/scripts/bridge-inbound.py`:
- `last_pull_ts`: advances only after the entire run completes successfully (existing behavior)
- `batch_resume_cursor`: written after each batch page (for resume-only, never advances pull window)

**TDD requirement:** Tests in w21-m5zd must be RED before starting. Run `python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'batch_checkpoint or batch_resume or last_pull_ts_not_advanced' --tb=line -q` and confirm failures. Then implement until all per-batch checkpoint tests pass GREEN.

**Implementation steps:**

1. Modify `fetch_jira_changes()` to accept an optional `on_batch_complete` callback:
   - Signature: `fetch_jira_changes(..., on_batch_complete: Callable[[int], None] | None = None) -> list[dict]`
   - After each successful page fetch, call `on_batch_complete(start_at + len(page))` if provided

2. Modify `process_inbound()` to write per-batch cursor:
   - Add `batch_cursor_key = "batch_resume_cursor"` to the checkpoint data
   - Pass `on_batch_complete` callback to `fetch_jira_changes()`:
     ```python
     def _save_batch_cursor(cursor: int) -> None:
         if checkpoint_file:
             current = json.loads(Path(checkpoint_file).read_text()) if Path(checkpoint_file).exists() else {}
             current["batch_resume_cursor"] = cursor
             Path(checkpoint_file).write_text(json.dumps(current))
     ```
   - The callback writes `batch_resume_cursor` to checkpoint file WITHOUT changing `last_pull_ts`

3. Add `resume_from_cursor` support to `process_inbound()`:
   - If `config.get("batch_resume_cursor")` is set and `config.get("resume", False)` is True:
     - Pass `start_at=batch_resume_cursor` as initial `start_at` in `fetch_jira_changes()`
   - After full run success: clear `batch_resume_cursor` from checkpoint and write new `last_pull_ts`

4. Ensure `last_pull_ts` is ONLY written at the end of a successful full run (no change to existing behavior, but verify tests confirm this)

**Files to modify:** plugins/dso/scripts/bridge-inbound.py

**Key constraint:** Per-batch cursor is for resume-only. It never affects the `last_pull_ts` pull window. A resumed run starts from the cursor page but the final `last_pull_ts` still uses the same start time as the original interrupted run.

## Acceptance Criteria

- [ ] All 5 per-batch checkpoint tests pass (GREEN)
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'batch_checkpoint or batch_resume or last_pull_ts_not_advanced' --tb=short -q 2>&1 | grep -q 'passed'
- [ ] All pre-existing bridge-inbound tests still pass
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py --tb=short -q 2>&1 | grep -q 'passed'
- [ ] last_pull_ts does NOT advance on mid-run failure
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py::test_last_pull_ts_not_advanced_on_mid_run_failure --tb=short -q 2>&1 | grep -q 'passed'
- [ ] batch_resume_cursor is written per page without changing last_pull_ts
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py::test_batch_resume_cursor_does_not_advance_last_pull_ts --tb=short -q 2>&1 | grep -q 'passed'
- [ ] Resume from cursor starts pagination at correct page
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py::test_per_batch_checkpoint_enables_resume --tb=short -q 2>&1 | grep -q 'passed'
- [ ] Per-batch cursor writes use atomic write (temp file + os.replace) to avoid partial writes on disk error
  Verify: python3 -c "import pathlib; content=pathlib.Path('$(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-inbound.py').read_text(); assert 'os.replace' in content or 'replace' in content, 'atomic write pattern not found'"
- [ ] ruff format --check and ruff check pass
  Verify: ruff format --check plugins/dso/scripts/bridge-inbound.py && ruff check plugins/dso/scripts/bridge-inbound.py

## Notes

**2026-03-22T03:36:34Z**

CHECKPOINT 6/6: Done ✓
