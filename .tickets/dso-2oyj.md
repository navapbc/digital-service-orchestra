---
id: dso-2oyj
status: open
deps: []
links: []
created: 2026-03-18T19:38:15Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-hmb3
---
# Write TDD test suite for plugins/dso/ directory structure validation

TDD RED phase: Write tests/scripts/test-plugin-dir-structure.sh that asserts the post-refactor plugins/dso/ layout exists. Run FIRST to confirm all tests fail before the file move. Tests: plugins/dso/{skills,hooks,commands,scripts,docs,.claude-plugin} exist; repo root no longer contains skills/,hooks/,commands/; marketplace.json has git-subdir; workflow-config.conf is git-tracked. Source tests/lib/assert.sh. Register in tests/scripts/run-all.sh. Script must be executable.


## ACCEPTANCE CRITERIA

- [ ] tests/scripts/test-plugin-dir-structure.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-plugin-dir-structure.sh
- [ ] Test file sources tests/lib/assert.sh (uses the test framework)
  Verify: grep -q 'assert.sh' $(git rev-parse --show-toplevel)/tests/scripts/test-plugin-dir-structure.sh
- [ ] Test file contains at least 8 test functions
  Verify: grep -c 'test_' $(git rev-parse --show-toplevel)/tests/scripts/test-plugin-dir-structure.sh | awk '{exit ($1 < 8)}'
- [ ] Running the test script exits non-zero before the file move (RED confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-plugin-dir-structure.sh; test $? -ne 0
- [ ] Test is registered in tests/scripts/run-all.sh
  Verify: grep -q 'test-plugin-dir-structure' $(git rev-parse --show-toplevel)/tests/scripts/run-all.sh
- [ ] bash tests/run-all.sh passes (exit 0) — existing tests must not break
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
