---
id: w20-3rjr
status: open
deps: []
links: []
created: 2026-03-21T16:32:06Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-6llo
---
# RED test: dep tree resolves archived tickets via tombstone

TDD RED phase for tombstone-based dep resolution. Write failing tests in tests/scripts/test-dep-tree-tombstone-resolution.sh asserting that tk dep tree shows archived tickets with their tombstone data instead of '[missing - treated as satisfied]'. Tests: (1) test_dep_tree_shows_archived_tombstone_status — dep tree shows archived dep with [closed] from tombstone, not [missing], (2) test_dep_tree_tombstone_shows_type — archived dep line includes ticket type from tombstone, (3) test_dep_tree_no_tombstone_falls_back_to_missing — when no tombstone and not in archive/.md, dep tree still shows [missing - treated as satisfied], (4) test_dep_tree_tombstone_overrides_missing_label — tombstone present; label is NOT 'missing'. Tests MUST FAIL (RED) against current tk implementation (which only shows [missing] for any absent ticket).

## ACCEPTANCE CRITERIA

- [ ] Test file exists at tests/scripts/test-dep-tree-tombstone-resolution.sh
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-dep-tree-tombstone-resolution.sh
- [ ] Test file contains at least 4 test functions matching test_dep_tree_
  Verify: grep -c 'test_dep_tree_' $(git rev-parse --show-toplevel)/tests/scripts/test-dep-tree-tombstone-resolution.sh | awk '{exit ($1 < 4)}'
- [ ] Tests fail RED without implementation (script exits non-zero when guard disabled)
  Verify: _RUN_ALL_ACTIVE=0 bash $(git rev-parse --show-toplevel)/tests/scripts/test-dep-tree-tombstone-resolution.sh 2>/dev/null; test $? -ne 0
- [ ] bash tests/run-all.sh passes exit 0 (suite-runner guard suppresses RED tests)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh

