---
id: dso-cz1m
status: in_progress
deps: [dso-ael7, dso-l77u]
links: []
created: 2026-03-21T16:10:03Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-p1y3
---
# RED tests: cross-worktree ticket state visibility integration test

Write integration tests that verify two worktrees sharing .tickets-tracker via symlink see the same ticket state instantly.

TDD Requirement (Integration Test — written after implementation): This task is an integration test task written after dso-ael7 and dso-l77u are implemented. Integration test exemption criterion applies: the unit-level behaviors are each covered by dso-6lhe and dso-smsg RED tests respectively. This integration test verifies the cross-component flow (symlink + canonical path working together end-to-end).

Create new test file tests/scripts/test-ticket-cross-worktree.sh with these tests:
- test_ticket_event_visible_in_second_worktree: Creates a real git repo with a tickets branch initialized, creates a git worktree, initializes ticket system in worktree (which creates symlink), writes a ticket event from main repo, and verifies the event file is visible from the worktree path (via symlink resolution).
- test_flock_canonical_path_prevents_parallel_write_corruption: Runs two concurrent write_commit_event calls — one via symlink path, one via real path — and verifies both succeed (exit 0) and both events are committed without corruption. Verifies the canonical path lock file is the same underlying inode for both callers.

These tests should pass GREEN after dso-ael7 and dso-l77u are implemented (hence the dependency on both). Write the tests to verify the integrated behavior, not as RED-first tests.

Files to create: tests/scripts/test-ticket-cross-worktree.sh


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0) — existing tests unaffected
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5
- [ ] `ruff check` passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] New test file exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-cross-worktree.sh
- [ ] 2 new test functions present in the file
  Verify: grep -c 'test_ticket_event_visible_in_second_worktree\|test_flock_canonical_path_prevents_parallel_write_corruption' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-cross-worktree.sh | awk '{exit ($1 < 2)}'
- [ ] Tests pass GREEN after dso-ael7 and dso-l77u are implemented
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-cross-worktree.sh 2>&1 | grep -c PASS | awk '{exit ($1 < 2)}'
