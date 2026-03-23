---
id: dso-pjcl
status: in_progress
deps: [dso-710r]
links: []
created: 2026-03-23T00:23:47Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2a9w
---
# RED: Write failing tests for cutover rollback (committed vs uncommitted detection)

TDD RED phase: append failing rollback tests to tests/scripts/test-cutover-tickets-migration.sh.
Tests must FAIL before T4 implementation.

1. test_cutover_rollback_uncommitted_uses_checkout
   Setup: temp git repo. Phase touches a file and exits non-zero WITHOUT committing.
   Assert: working-tree modification is reversed after script exits; exit code non-zero.

2. test_cutover_rollback_committed_uses_revert
   Setup: temp git repo. Phase makes a file change and commits it; later phase exits non-zero.
   Assert: committed change absent in HEAD after rollback (git revert applied); exit code non-zero.

3. test_cutover_exits_with_error_and_log_path_on_failure
   Setup: temp git repo. Force any phase to exit non-zero.
   Assert: stderr contains ERROR and the log file path; exit code non-zero.

4. test_cutover_rollback_distinguishes_commit_boundary
   Critical adversarial case: when pre-commit hook REJECTS a commit (exits 1, HEAD unchanged), rollback must use working-tree reset, NOT git revert.
   Setup: temp git repo with pre-commit hook that always exits 1.
   Phase: modifies file, runs git add, attempts git commit (hook rejects it).
   Assert: rollback does working-tree reset; HEAD unchanged (no new commits, no reverted commits).

Fixture: git init in TMPDIR, configure user.email and user.name, create initial commit. Use trap for cleanup.
Append to existing test file from T1 — do NOT overwrite T1 tests.

Failure injection: use CUTOVER_PHASE_EXIT_OVERRIDE env var (from T2 implementation) to make a named phase exit non-zero, e.g., CUTOVER_PHASE_EXIT_OVERRIDE="MIGRATE=1". For tests that need a phase to commit before failing, use CUTOVER_PHASE_EXIT_OVERRIDE="VALIDATE=1" after manually injecting a commit in a custom phase setup if needed — or write the test to use a test harness that wraps the phase function.

## Acceptance Criteria

- [ ] File contains test_cutover_rollback_uncommitted_uses_checkout
  Verify: grep -q 'test_cutover_rollback_uncommitted_uses_checkout' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] File contains test_cutover_rollback_committed_uses_revert
  Verify: grep -q 'test_cutover_rollback_committed_uses_revert' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] File contains test_cutover_exits_with_error_and_log_path_on_failure
  Verify: grep -q 'test_cutover_exits_with_error_and_log_path_on_failure' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] File contains test_cutover_rollback_distinguishes_commit_boundary
  Verify: grep -q 'test_cutover_rollback_distinguishes_commit_boundary' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] Syntax check passes on test file
  Verify: bash --norc $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh --check-syntax 2>/dev/null || bash -n $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh
- [ ] New rollback tests FAIL before T4 implementation (RED state)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'FAIL.*rollback\|FAIL.*error_and_log'


## Notes

**2026-03-23T02:05:47Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T02:05:51Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T02:06:52Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-23T02:06:56Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T02:07:28Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-23T02:07:33Z**

CHECKPOINT 6/6: Done ✓
