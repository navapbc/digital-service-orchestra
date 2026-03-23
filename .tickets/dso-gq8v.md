---
id: dso-gq8v
status: open
deps: [dso-pjcl]
links: []
created: 2026-03-23T00:24:07Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2a9w
---
# Implement cutover rollback logic: detect committed vs uncommitted failure and revert

Implement rollback logic in plugins/dso/scripts/cutover-tickets-migration.sh.

Key design decisions from adversarial review:
- Before each phase executes, capture git rev-parse HEAD into PHASE_COMMIT_BEFORE
- After a phase exits non-zero, compare current HEAD to PHASE_COMMIT_BEFORE:
  - If HEAD == PHASE_COMMIT_BEFORE: phase produced only working-tree changes (or no changes). Rollback: git checkout HEAD -- . (or git restore .) to discard any staged/unstaged changes.
  - If HEAD != PHASE_COMMIT_BEFORE: phase committed at least one commit. Rollback: git revert HEAD (using git-revert-safe.sh or equivalent) to undo the committed change.
- This distinction correctly handles the case where a pre-commit hook rejects a git commit attempt: the hook exits non-zero but HEAD does not advance, so HEAD == PHASE_COMMIT_BEFORE, and the rollback correctly uses working-tree reset instead of git revert.

Rollback steps after detection:
1. Log rollback action to log file and stderr
2. Execute appropriate rollback (checkout/restore vs revert)
3. Log 'Rollback complete' or 'Rollback failed: ERROR' to both log and stderr
4. Print 'ERROR: phase PHASE_NAME failed — see LOG_PATH' to stderr
5. Exit with non-zero code

Consider using git-revert-safe.sh (plugins/dso/scripts/git-revert-safe.sh) for the revert path.

TDD FIRST: implement only after T3 tests are confirmed RED.

## Acceptance Criteria

- [ ] test_cutover_rollback_uncommitted_uses_checkout PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_rollback_uncommitted_uses_checkout'
- [ ] test_cutover_rollback_committed_uses_revert PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_rollback_committed_uses_revert'
- [ ] test_cutover_exits_with_error_and_log_path_on_failure PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_exits_with_error_and_log_path_on_failure'
- [ ] test_cutover_rollback_distinguishes_commit_boundary PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_rollback_distinguishes_commit_boundary'
- [ ] Script detects committed vs uncommitted state via git rev-parse HEAD before and after phase
  Verify: grep -q 'rev-parse\|PHASE_COMMIT_BEFORE\|_phase_commit_hash\|commit_before' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] Script performs working-tree reset for uncommitted failures
  Verify: grep -q 'checkout HEAD\|reset --hard\|restore\|git clean' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] Script performs git revert for committed failures
  Verify: grep -q 'git revert\|revert' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] When rollback itself fails (git revert/checkout returns non-zero), script logs rollback failure to stderr and still exits non-zero with the original error — rollback failure does not swallow original error
  Verify: grep -q 'Rollback failed\|rollback_exit\|revert_rc\|checkout_rc\|rollback.*fail' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh

