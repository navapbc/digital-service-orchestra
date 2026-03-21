---
id: dso-6lhe
status: in_progress
deps: []
links: []
created: 2026-03-21T16:08:50Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-p1y3
---
# RED tests: ticket-init.sh symlink creation in git worktrees

Write failing tests for symlink creation behavior in ticket-init.sh when run from a git worktree.

TDD Requirement: Write these failing tests in tests/scripts/test-ticket-init.sh (add to existing test file):
- test_ticket_init_creates_symlink_in_worktree: When run from a git worktree (.git is a file), 'ticket init' creates .tickets-tracker as a symlink pointing to the main repo's .tickets-tracker/.
- test_ticket_init_symlink_points_to_real_dir: The symlink target resolves to a valid directory.
- test_ticket_init_idempotent_when_symlink_exists: Re-running init when .tickets-tracker is already a symlink exits 0.
- test_ticket_init_handles_real_dir_before_symlink: When a real .tickets-tracker/ directory exists in a worktree (from prior auto-init), 'ticket init' replaces it with a symlink without error.
- test_auto_detect_main_worktree_via_git_list: git worktree list --porcelain is parsed to find the main (non-worktree) repo path whose .tickets-tracker is used as the symlink target.

All tests must return non-zero (RED) before ticket-init.sh symlink logic is implemented.

Files to create/edit: tests/scripts/test-ticket-init.sh (add new tests; do not remove existing ones)


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0) — existing tests unaffected
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5
- [ ] `ruff check` passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] 5 new test functions added to test-ticket-init.sh matching specified names
  Verify: grep -c 'test_ticket_init_creates_symlink_in_worktree\|test_ticket_init_symlink_points_to_real_dir\|test_ticket_init_idempotent_when_symlink_exists\|test_ticket_init_handles_real_dir_before_symlink\|test_auto_detect_main_worktree_via_git_list' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-init.sh | awk '{exit ($1 < 5)}'
- [ ] New tests fail RED before symlink logic exists
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-init.sh 2>&1 | grep -q 'FAIL.*symlink\|symlink.*FAIL'

## Notes

**2026-03-21T16:58:09Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T16:58:28Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T16:59:16Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T17:20:45Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED test task — no implementation needed, only test writing)

**2026-03-21T17:20:54Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T17:21:11Z**

CHECKPOINT 6/6: Done ✓ — 5 RED tests added (Tests 8-12), all fail before symlink logic exists; existing 14 tests unaffected
