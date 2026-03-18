---
id: dso-yh8q
status: in_progress
deps: []
links: []
created: 2026-03-18T16:39:53Z
type: bug
priority: 3
assignee: Joe Oakhart
parent: dso-ojbb
---
# Fix: dso-setup.sh dryrun pre-commit message should check pre-commit availability

In `scripts/dso-setup.sh`, the `--dryrun` preview message for the `pre-commit install` step always prints "Would run: pre-commit install && pre-commit install --hook-type pre-push", even when `pre-commit` is not installed on the system. The real code guards this with `command -v pre-commit`, so the dryrun message is misleading on systems without pre-commit.

Fix: only print the dryrun pre-commit message when `command -v pre-commit` succeeds. When pre-commit is absent, print nothing (or a note that it would be skipped).

## ACCEPTANCE CRITERIA

- [ ] Dryrun pre-commit message is conditional on pre-commit availability
  Verify: grep -A3 'pre-commit install' $(git rev-parse --show-toplevel)/scripts/dso-setup.sh | grep -q 'command -v pre-commit\|DRYRUN.*pre-commit'
- [ ] all 26 tests continue to pass
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -q 'FAILED: 0'
- [ ] ruff check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py

## Notes

**2026-03-18T16:54:25Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T16:54:28Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-18T16:54:30Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-18T16:54:39Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-18T16:54:58Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-18T16:55:18Z**

CHECKPOINT 6/6: Done ✓

**2026-03-18T16:59:33Z**

CHECKPOINT 6/6: Done ✓ — Batch 3 complete, review passed.
