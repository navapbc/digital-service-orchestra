---
id: dso-hq8y
status: closed
deps: []
links: []
created: 2026-03-17T22:18:28Z
type: task
priority: 2
assignee: Joe Oakhart
---
# Pre-existing test failures in run-all.sh suites (hook/script tests)


## Notes

<!-- note-id: dtq4gyc2 -->
<!-- timestamp: 2026-03-17T22:18:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Pre-existing failures (not introduced by dso-42eg sprint):
- tests/hooks/test-config-paths.sh: 13 fail (CLAUDE_PLUGIN_ROOT unbound in test env)
- tests/scripts/test-smoke-test-portable.sh: 1 fail (validate-config.sh exits 1 with minimal config)
- tests/scripts/test-flat-config-e2e.sh: 2 fail (nested_key lookup)
- tests/scripts/test-pre-commit-wrapper.sh: 3 fail
- tests/scripts/test-read-config-flat.sh: 2 fail
- tests/hooks/test-commit-tracker.sh: 1 fail
- tests/hooks/test-hooks-json-paths.sh: 1 fail (was already M in git status at sprint start)
- tests/hooks/test-performance-validation.sh: 2 fail (was already M at sprint start)
- tests/hooks/test-pre-compact-marker.sh: 2 fail
- tests/hooks/test-pre-compact.sh: 1 fail
- tests/hooks/test-shell-safety-directives.sh: 1 fail
- tests/hooks/test-post-tool-use-hooks.sh: 0+0 (format issue)
- tests/hooks/test-format-fix.sh: 0+0 (format issue)
None of these test files were modified by any commit in the dso-42eg sprint.
