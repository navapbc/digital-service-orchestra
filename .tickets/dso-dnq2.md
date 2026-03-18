---
id: dso-dnq2
status: in_progress
deps: [dso-oqto]
links: []
created: 2026-03-18T17:30:10Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-mjdp
---
# Delete hooks/pre-compact-checkpoint.sh, post-compact-review-check.sh, and pre-push-sentinel-check.sh

Delete three hook script files that implement the checkpoint and sentinel infrastructure. These files must be removed after the PreCompact hook is deregistered in plugin.json (predecessor task).

## Files to Delete
- hooks/pre-compact-checkpoint.sh
- hooks/post-compact-review-check.sh
- hooks/pre-push-sentinel-check.sh

## Implementation Steps
1. Confirm plugin.json no longer contains the PreCompact block (predecessor task dso-oqto must be complete)
2. Run: rm hooks/pre-compact-checkpoint.sh hooks/post-compact-review-check.sh hooks/pre-push-sentinel-check.sh
3. Verify no remaining code in hooks/ references these deleted files (run grep to confirm no dispatcher or lib file sources or calls them directly)
4. Note: tests/hooks/test-pre-push-sentinel-check.sh references pre-push-sentinel-check.sh — this test file deletion is OUT OF SCOPE (handled by dso-8fc5). The test will fail after deletion; the test itself is scheduled for removal in a sibling story.

## TDD Requirement (RED before GREEN)
Write this failing test first for each file:
  test -f hooks/pre-compact-checkpoint.sh && echo RED || echo GREEN
  # Before deletion: outputs RED (file exists) — test is RED
  # After deletion: outputs GREEN (file absent) — test is GREEN

Also write:
  test -f hooks/post-compact-review-check.sh && echo RED || echo GREEN
  test -f hooks/pre-push-sentinel-check.sh && echo RED || echo GREEN

## Constraints
- Only deletion of the three listed hook files
- Do NOT delete the test file tests/hooks/test-pre-push-sentinel-check.sh (out of scope)
- Do NOT modify dispatchers, lib scripts, or any shared hooks
- After deletion, bash tests/run-all.sh may fail due to the test referencing pre-push-sentinel-check.sh — this is expected and tracked by dso-8fc5

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes — CONDITIONAL: this criterion is green only after sibling story dso-8fc5 has deleted tests/hooks/test-pre-push-sentinel-check.sh. This task (dso-dnq2) and dso-8fc5 must be committed in the same sprint batch to achieve a fully green test suite. Do NOT mark this task complete based on a run of tests/run-all.sh that includes the still-present test-pre-push-sentinel-check.sh failure.
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py
- [ ] `ruff format --check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check scripts/*.py tests/**/*.py
- [ ] hooks/pre-compact-checkpoint.sh does not exist
  Verify: ! test -f hooks/pre-compact-checkpoint.sh
- [ ] hooks/post-compact-review-check.sh does not exist
  Verify: ! test -f hooks/post-compact-review-check.sh
- [ ] hooks/pre-push-sentinel-check.sh does not exist
  Verify: ! test -f hooks/pre-push-sentinel-check.sh
- [ ] No dispatcher or lib file in hooks/ directly references the deleted scripts
  Verify: ! grep -rq 'pre-compact-checkpoint\|post-compact-review-check\|pre-push-sentinel-check' hooks/dispatchers/ hooks/lib/ 2>/dev/null
- [ ] plugin.json contains no PreCompact key (predecessor task dso-oqto verified complete)
  Verify: ! grep -q 'PreCompact' .claude-plugin/plugin.json
