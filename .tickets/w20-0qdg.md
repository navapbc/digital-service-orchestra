---
id: w20-0qdg
status: closed
deps: [w20-v9eo, w20-p35v, w20-9zaj]
links: []
created: 2026-03-21T16:32:44Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-6llo
---
# E2E test: archive → tombstone → dep tree resolution

E2E integration test covering the full archive→tombstone→dep-tree flow. Test file: tests/scripts/test-archive-tombstone-e2e.sh. Tests: (1) test_e2e_archive_creates_tombstone_and_dep_tree_resolves — create a ticket A (dep on B), close B, run archive-closed-tickets.sh, verify tombstone at .tickets/archive/tombstones/B.json exists, then run 'tk dep tree A' and assert B is shown as '[archived: closed ...]' not '[missing]', (2) test_e2e_tombstone_survives_second_archive_run — run archive twice; tombstone for B must not be overwritten or duplicated, (3) test_e2e_no_tombstone_for_protected_ticket — ticket C is closed but has an open child D; archive run must not create tombstone for C. Tests depend on T2 (tombstone write) and T4 (dep tree resolution) being implemented. TDD Requirement: Run bash tests/scripts/test-archive-tombstone-e2e.sh — all 3 tests pass GREEN.

## ACCEPTANCE CRITERIA

- [ ] Test file exists at tests/scripts/test-archive-tombstone-e2e.sh
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-archive-tombstone-e2e.sh
- [ ] E2E test passes — archive creates tombstone AND dep tree resolves via tombstone
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-archive-tombstone-e2e.sh
- [ ] Tombstone idempotent — second archive run does not duplicate or overwrite
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-archive-tombstone-e2e.sh
- [ ] Protected ticket (open child) receives no tombstone
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-archive-tombstone-e2e.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh

