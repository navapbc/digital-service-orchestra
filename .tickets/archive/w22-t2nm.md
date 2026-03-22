---
id: w22-t2nm
status: closed
deps: [w22-pccy, w22-ah0i]
links: []
created: 2026-03-22T20:00:38Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-nv42
---
# Implement diff size thresholds and merge commit detection in classifier

Add diff size threshold computation and merge commit detection to `plugins/dso/scripts/review-complexity-classifier.sh`, emitting three new JSON fields per the `classifier-size-output` contract (task w22-ah0i).

**Implementation steps**:

1. **Add `_diff_size_lines_raw()` function** — returns the raw count of added lines in non-test, non-generated source files. Logic:
   - Reuse the same line-counting loop as existing `_diff_lines()` but return an integer count instead of 0/1
   - Exclude test files (via `is_test_file()`)
   - Exclude generated files: files matching `*/migrations/*`, `*.lock`, `*package-lock.json`, `*yarn.lock`, `*poetry.lock`, `*.generated.*`, `*/generated/*`, or commit messages indicating auto-generation
   - Count only lines starting with `+` (not `++` diff header lines)

2. **Add `_is_merge_commit()` function** — returns `true`/`false`:
   - Check `$MOCK_MERGE_HEAD` env var first (for test isolation; if set to "1", return true)
   - Check if `.git/MERGE_HEAD` file exists and is non-empty: `git rev-parse --git-dir` to find git dir, then check `MERGE_HEAD` file
   - Also detect via `git log -1 --pretty=%P 2>/dev/null | wc -w` — if parent count ≥ 2, it's a merge commit (handles cases where MERGE_HEAD is gone but commit is already merged)
   - Handle edge cases: shallow clone (git log failure → return false); no git (→ return false)

3. **Add `_compute_size_action()` function** — takes `diff_size_lines` and `is_merge_commit` as args:
   - If `is_merge_commit` is true → return `"none"` (bypass)
   - If `diff_size_lines` ≥ 600 → return `"reject"`
   - If `diff_size_lines` ≥ 300 → return `"upgrade"`
   - Otherwise → return `"none"`

4. **Extend JSON output** — after existing COMPUTED_TOTAL/SELECTED_TIER logic, add:
   ```bash
   DIFF_SIZE_LINES=$(_diff_size_lines_raw)
   IS_MERGE=$(  _is_merge_commit && echo "true" || echo "false")
   SIZE_ACTION=$(_compute_size_action "$DIFF_SIZE_LINES" "$IS_MERGE")
   ```
   Update the final `printf` to include: `"diff_size_lines":%d,"size_action":"%s","is_merge_commit":%s`

5. **Update telemetry** — include new fields in the telemetry JSONL append (same printf format as stdout output).

6. **Handle octopus merges** — if `git log -1 --pretty=%P` returns 3+ parents, treat as merge commit (return true from `_is_merge_commit()`).

**Edge cases**:
- Shallow clone where `git log` fails: `_is_merge_commit()` must return `false` (fail-safe, not fail-open)
- Empty diff: existing early-exit already outputs `{}` — extend it to include the three new fields with `diff_size_lines:0, size_action:"none", is_merge_commit:false`

**TDD Requirement**: Depends on RED test task w22-pccy. Before implementing, run `bash tests/hooks/test-review-complexity-classifier.sh` and confirm all 9 new tests fail. After implementation, all 9 must pass.

**Files**:
- `plugins/dso/scripts/review-complexity-classifier.sh` (Edit — add three new functions and extend JSON output)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Classifier outputs `diff_size_lines` as integer in JSON
  Verify: echo "" | bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d['diff_size_lines'], int)"
- [ ] Classifier outputs `size_action` as one of "none", "upgrade", "reject"
  Verify: echo "" | bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['size_action'] in ['none','upgrade','reject']"
- [ ] Classifier outputs `is_merge_commit` as boolean
  Verify: echo "" | bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d['is_merge_commit'], bool)"
- [ ] A 600-line non-test diff yields `size_action` = "reject"
  Verify: python3 -c "print('diff --git a/src/foo.py b/src/foo.py\nindex 0000000..1111111 100644\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -1 +1,601 @@\n' + '\n'.join(['+x = 1' for _ in range(600)]))" | bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['size_action']=='reject', d['size_action']"
- [ ] A 300-line non-test diff yields `size_action` = "upgrade"
  Verify: python3 -c "print('diff --git a/src/foo.py b/src/foo.py\nindex 0000000..1111111 100644\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -1 +1,301 @@\n' + '\n'.join(['+x = 1' for _ in range(300)]))" | bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['size_action']=='upgrade', d['size_action']"
- [ ] MOCK_MERGE_HEAD=1 forces `is_merge_commit` = true and `size_action` = "none"
  Verify: python3 -c "print('diff --git a/src/foo.py b/src/foo.py\nindex 0000000..1111111 100644\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -1 +1,601 @@\n' + '\n'.join(['+x = 1' for _ in range(600)]))" | MOCK_MERGE_HEAD=1 bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['is_merge_commit']==True and d['size_action']=='none', d"
- [ ] All 9 RED tests from task w22-pccy now pass GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh 2>&1 | grep -v "^FAIL" | grep -q "PASS\|ok\|passed"
- [ ] `MOCK_MERGE_HEAD` is documented as a test-only bypass with a `# TEST ONLY` comment adjacent to the env var check in the script (gap analysis finding: undocumented bypass variable can be exploited in production)
  Verify: grep -A2 "MOCK_MERGE_HEAD" $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh | grep -qi "test\|bypass\|only"

## Notes

<!-- note-id: 2cjb0luk -->
<!-- timestamp: 2026-03-22T21:19:57Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 0dhn39ln -->
<!-- timestamp: 2026-03-22T21:20:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: tcc2etl2 -->
<!-- timestamp: 2026-03-22T21:20:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (pre-existing RED tests from w22-pccy — 9 tests, 10 assertions, all failing) ✓

<!-- note-id: kximphos -->
<!-- timestamp: 2026-03-22T21:21:35Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: 4rjwj0zo -->
<!-- timestamp: 2026-03-22T21:22:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: ur2ydj1x -->
<!-- timestamp: 2026-03-22T21:22:52Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

**2026-03-22T21:33:02Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/scripts/review-complexity-classifier.sh. Tests: 9 RED tests now GREEN.
