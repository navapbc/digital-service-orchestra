---
id: dso-meet
status: closed
deps: []
links: []
created: 2026-03-18T16:39:52Z
type: bug
priority: 3
assignee: Joe Oakhart
parent: dso-ojbb
---
# Fix: dso-setup.sh dryrun messages should reflect conditional copy logic (only if absent)

In `scripts/dso-setup.sh`, the `--dryrun` preview messages for `.pre-commit-config.yaml` and `ci.yml` say "Would copy ... -> ..." unconditionally, even though the real code only copies if the destination file does not already exist. This misleads users who already have these files into thinking they would be overwritten.

Fix: append "(only if absent)" to the `[dryrun]` messages for these conditional copy operations:
- `[dryrun] Would copy ... -> .pre-commit-config.yaml (only if absent)`
- `[dryrun] Would copy ... -> .github/workflows/ci.yml (only if absent)`

## ACCEPTANCE CRITERIA

- [ ] .pre-commit-config.yaml dryrun message contains "(only if absent)"
  Verify: grep -q 'pre-commit-config.yaml.*only if absent\|only if absent.*pre-commit-config.yaml' $(git rev-parse --show-toplevel)/scripts/dso-setup.sh
- [ ] ci.yml dryrun message contains "(only if absent)"
  Verify: grep -q 'ci.yml.*only if absent\|only if absent.*ci.yml' $(git rev-parse --show-toplevel)/scripts/dso-setup.sh
- [ ] all 26 tests continue to pass
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -q 'FAILED: 0'
- [ ] ruff check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py

## Notes

**2026-03-18T16:52:16Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T16:52:23Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-18T16:52:26Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-18T16:52:35Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-18T16:53:00Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-18T16:53:55Z**

CHECKPOINT 6/6: Done ✓

**2026-03-18T16:59:33Z**

CHECKPOINT 6/6: Done ✓ — Batch 3 complete, review passed.
