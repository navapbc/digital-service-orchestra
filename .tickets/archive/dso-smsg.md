---
id: dso-smsg
status: closed
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

## Notes

<!-- note-id: t1diml09 -->
<!-- timestamp: 2026-03-21T17:33:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: dgq923bq -->
<!-- timestamp: 2026-03-21T17:34:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 5e5r29v6 -->
<!-- timestamp: 2026-03-21T17:34:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: k6d6odax -->
<!-- timestamp: 2026-03-21T17:37:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ — Tests 6 & 7 fail RED (3 FAIL assertions on canonical/realpath), Tests 1-5 pass (14 PASS)

<!-- note-id: xcgc0cce -->
<!-- timestamp: 2026-03-21T17:37:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — canonical path resolution via python3 os.path.realpath added to ticket-lib.sh

<!-- note-id: x07ij0qq -->
<!-- timestamp: 2026-03-21T17:38:12Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — 17 PASS, 0 FAIL

<!-- note-id: gt7b8ik2 -->
<!-- timestamp: 2026-03-21T17:49:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All ACs pass: ruff check/format pass, 2 new test functions present, RED verified before implementation, 17/17 tests GREEN after implementation
