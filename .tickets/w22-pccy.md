---
id: w22-pccy
status: in_progress
deps: []
links: []
created: 2026-03-22T20:00:04Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-nv42
---
# RED tests: classifier diff size thresholds and merge commit detection

Write failing (RED) tests in `tests/hooks/test-review-complexity-classifier.sh` for the diff size threshold and merge commit detection behaviors not yet implemented in `review-complexity-classifier.sh`.

**Tests to add** (append to the end of the existing test file, after the existing passing tests):

1. `test_classifier_diff_size_lines_raw_count` — assert `diff_size_lines` in JSON output is an integer ≥ 0; create a diff with 50 non-test added lines and verify `diff_size_lines` equals 50 (will fail because field doesn't exist yet)
2. `test_classifier_size_action_none_below_300` — diff with 10 scorable lines → `size_action` = "none"
3. `test_classifier_size_action_upgrade_at_300` — diff with 300 scorable added lines → `size_action` = "upgrade"
4. `test_classifier_size_action_reject_at_600` — diff with 600+ scorable added lines → `size_action` = "reject"
5. `test_classifier_size_action_none_for_test_only_diff` — diff touching only test files → `size_action` = "none" regardless of line count (bypass at Standard tier)
6. `test_classifier_size_action_none_for_generated_files` — diff touching only migration/lock files → `size_action` = "none" (generated code bypass)
7. `test_classifier_is_merge_commit_false_default` — normal diff → `is_merge_commit` = false
8. `test_classifier_is_merge_commit_size_action_none` — when `is_merge_commit` is true (mocked via env var `MOCK_MERGE_HEAD=1`), `size_action` = "none" even with 600+ lines
9. `test_classifier_output_includes_new_fields` — verify JSON output contains `diff_size_lines`, `size_action`, and `is_merge_commit` keys

**Test approach**: Use the existing `create_diff_fixture` helper to generate diff content with controlled line counts. For merge commit simulation, use a test env var `MOCK_MERGE_HEAD` that the classifier reads in test mode (or mock the `_is_merge_commit` function).

**Fuzzy match check**: Source file is `review-complexity-classifier.sh`; normalized: `reviewcomplexityclassifiersh`. Test file is `test-review-complexity-classifier.sh`; normalized: `testreviewcomplexityclassifiersh`. Substring match confirmed — no `.test-index` entry needed.

**TDD Requirement**: This IS the RED test task. Write all tests listed above and confirm they fail before any implementation. Run: `bash tests/hooks/test-review-complexity-classifier.sh 2>&1 | tail -20` to verify RED state.

**Files**:
- `tests/hooks/test-review-complexity-classifier.sh` (Edit — append new test functions and add them to the runner block at the end)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0) — existing tests still pass
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] All 9 new test functions exist in `tests/hooks/test-review-complexity-classifier.sh`
  Verify: grep -c "^test_classifier_diff_size_lines_raw_count\|^test_classifier_size_action_none_below_300\|^test_classifier_size_action_upgrade_at_300\|^test_classifier_size_action_reject_at_600\|^test_classifier_size_action_none_for_test_only_diff\|^test_classifier_size_action_none_for_generated_files\|^test_classifier_is_merge_commit_false_default\|^test_classifier_is_merge_commit_size_action_none\|^test_classifier_output_includes_new_fields" $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh | awk '{exit ($1 < 9)}'
- [ ] New tests fail (RED) when run against current classifier (before implementation task)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh 2>&1 | grep -q "FAIL\|error\|not found"
- [ ] New test functions are registered in the runner block at the bottom of the test file
  Verify: grep -q "test_classifier_diff_size_lines_raw_count" $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] All 9 new test function names appear in the runner execution block (after the function definitions, not only as definitions), confirming they will be invoked when the test file is run (gap analysis finding: functions appended after runner block are never executed)
  Verify: awk '/^test_classifier_diff_size_lines_raw_count[^(]/{found=1} END{exit(!found)}' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh

## Notes

<!-- note-id: ifz0mf53 -->
<!-- timestamp: 2026-03-22T20:11:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 0nm1uk9x -->
<!-- timestamp: 2026-03-22T20:11:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: ujdm6qe2 -->
<!-- timestamp: 2026-03-22T20:12:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: hgu2k2p4 -->
<!-- timestamp: 2026-03-22T20:45:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: ir4kh2k8 -->
<!-- timestamp: 2026-03-22T20:59:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: nopd81b8 -->
<!-- timestamp: 2026-03-22T20:59:17Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

**2026-03-22T21:02:03Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/hooks/test-review-complexity-classifier.sh (modified). Tests: 9 RED tests added.
