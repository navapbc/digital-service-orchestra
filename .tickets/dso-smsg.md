---
id: dso-smsg
status: open
deps: []
links: []
created: 2026-03-21T16:09:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-p1y3
---
# RED tests: canonical path resolution in write_commit_event (ticket-lib.sh)

Write failing tests for canonical path (realpath) resolution in write_commit_event when .tickets-tracker is a symlink.

TDD Requirement: Add these failing tests to tests/scripts/test-ticket-lib.sh:
- test_write_commit_event_resolves_symlink_to_real_path: Sets up a symlinked .tickets-tracker/ pointing to a real dir, calls write_commit_event, and verifies the lock file and git operations use the real (canonical) path, not the symlink path.
- test_write_commit_event_flock_on_canonical_path: Confirms that two concurrent callers — one using the symlink path, one using the real path — both acquire the same underlying lock (flock on canonical path prevents simultaneous commits even across symlink/real-path differences).

These tests must fail (RED) before canonical path resolution is added to ticket-lib.sh.

Files to edit: tests/scripts/test-ticket-lib.sh (add new tests; do not remove existing ones)


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0) — existing tests unaffected
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5
- [ ] `ruff check` passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] 2 new test functions added to test-ticket-lib.sh matching specified names
  Verify: grep -c 'test_write_commit_event_resolves_symlink_to_real_path\|test_write_commit_event_flock_on_canonical_path' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-lib.sh | awk '{exit ($1 < 2)}'
- [ ] New tests fail RED before canonical path resolution is implemented
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-lib.sh 2>&1 | grep -q 'FAIL.*canonical\|canonical.*FAIL\|FAIL.*symlink\|symlink.*FAIL'
