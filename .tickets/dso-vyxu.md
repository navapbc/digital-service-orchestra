---
id: dso-vyxu
status: open
deps: [dso-cz1m]
links: []
created: 2026-03-21T16:10:19Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-p1y3
---
# Integration verification: cross-worktree tests pass GREEN

Verify that after dso-ael7 (symlink creation) and dso-l77u (canonical path) are implemented, the cross-worktree integration tests from dso-cz1m pass GREEN.

TDD Requirement: Unit exemption criterion applies — this task contains no conditional logic. It is pure verification scaffolding: run the existing tests and confirm they pass. No new behavioral code is written. Exemption criterion: 'infrastructure-boundary-only — touches only test execution, no business logic' + 'change-detector test — asserts existing tests pass'.

Implementation steps:
1. Run bash tests/scripts/test-ticket-cross-worktree.sh — verify exit 0.
2. If tests fail, investigate and fix any integration issues (do not modify test assertions; fix the implementation tasks if needed).
3. Update any documentation if an unexpected edge case was discovered during integration.

This task has no source code changes. Its sole deliverable is a green test suite run for the cross-worktree integration tests.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5
- [ ] `ruff check` passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] Cross-worktree integration tests pass GREEN (both tests)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-cross-worktree.sh 2>&1 | grep -E 'test_ticket_event_visible_in_second_worktree.*PASS|test_flock_canonical_path_prevents_parallel_write_corruption.*PASS'
- [ ] Full test suite exits 0
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh; echo "exit: $?"
