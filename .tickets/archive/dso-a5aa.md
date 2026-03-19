---
id: dso-a5aa
status: closed
deps: []
links: []
created: 2026-03-18T23:14:39Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-guxa
---
# Remove dead test-plugin orphan pattern from session-misc-functions.sh and update test-nohup-cleanup.sh fixture

Remove the dead 'timeout.*make.*test-plugin' pattern from hook_cleanup_orphaned_processes in session-misc-functions.sh and update the test fixture in test-nohup-cleanup.sh to use a different representative command.

TDD Requirement: Write failing test FIRST.
In tests/hooks/test-nohup-cleanup.sh or a test helper, add test_no_test_plugin_orphan_pattern that greps plugins/dso/hooks/lib/session-misc-functions.sh to confirm 'test-plugin' is NOT in the PATTERNS array. Run test to confirm RED. Then:

1. In plugins/dso/hooks/lib/session-misc-functions.sh, remove from hook_cleanup_orphaned_processes PATTERNS array (~line 50):
   'timeout.*make.*test-plugin'
2. In tests/hooks/test-nohup-cleanup.sh, in the 'multiple entry files mixed cleanup' test (~line 171-172), update the fixture:
   From: command=timeout 300 make test-plugin
   To:   command=timeout 300 make test-e2e
3. Add test_no_test_plugin_orphan_pattern assertion to tests/hooks/test-nohup-cleanup.sh:
   _NO_PLUGIN_PATTERN='yes'
   grep -q 'test-plugin' "$DSO_PLUGIN_DIR/hooks/lib/session-misc-functions.sh" && _NO_PLUGIN_PATTERN='no' || true
   assert_eq 'test_no_test_plugin_orphan_pattern' 'yes' "$_NO_PLUGIN_PATTERN"

After changes, run bash tests/run-all.sh to confirm GREEN.

Files: plugins/dso/hooks/lib/session-misc-functions.sh, tests/hooks/test-nohup-cleanup.sh

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] session-misc-functions.sh PATTERNS array does not contain 'test-plugin'
  Verify: ! grep -q 'test-plugin' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/session-misc-functions.sh
- [ ] test-nohup-cleanup.sh fixture uses 'make test-e2e' instead of 'make test-plugin'
  Verify: grep -q 'make test-e2e' $(git rev-parse --show-toplevel)/tests/hooks/test-nohup-cleanup.sh && ! grep -q 'make test-plugin' $(git rev-parse --show-toplevel)/tests/hooks/test-nohup-cleanup.sh
- [ ] New test_no_test_plugin_orphan_pattern test exists in test-nohup-cleanup.sh
  Verify: grep -q 'test_no_test_plugin_orphan_pattern' $(git rev-parse --show-toplevel)/tests/hooks/test-nohup-cleanup.sh

## File Impact
- `plugins/dso/hooks/lib/session-misc-functions.sh` - Remove dead 'timeout.*make.*test-plugin' pattern from hook_cleanup_orphaned_processes PATTERNS array
- `tests/hooks/test-nohup-cleanup.sh` - Update fixture from 'make test-plugin' to 'make test-e2e', add new test_no_test_plugin_orphan_pattern test assertion

## Notes

<!-- note-id: lvkbd0qs -->
<!-- timestamp: 2026-03-18T23:39:55Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/hooks/lib/session-misc-functions.sh, tests/hooks/test-nohup-cleanup.sh. Tests: pass (53/53). Review: pass (score=5). Merged to main: 50173f6.

<!-- note-id: enf8ni83 -->
<!-- timestamp: 2026-03-18T23:39:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: removed dead test-plugin orphan pattern from session-misc-functions.sh PATTERNS array; updated test fixture and added test_no_test_plugin_orphan_pattern in test-nohup-cleanup.sh
