---
id: dso-2e99
status: closed
deps: []
links: []
created: 2026-03-21T00:31:14Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# fix: ci-status.sh crashes with CFG_PYTHON_VENV unbound variable when config-paths.sh is absent


## Notes

<!-- note-id: qqi7tt0k -->
<!-- timestamp: 2026-03-21T00:31:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Same anti-pattern as dso-tqvy (fixed in worktree-sync-from-main.sh). ci-status.sh line 212 uses $CFG_PYTHON_VENV inside ${repo_root:+$repo_root/$CFG_PYTHON_VENV} inside _find_python_with_yaml(). If config-paths.sh is not found (e.g., CLAUDE_PLUGIN_ROOT without hooks/lib/config-paths.sh), the variable is unbound. When repo_root is non-empty, the ${repo_root:+...} expansion evaluates the inner $CFG_PYTHON_VENV, triggering 'unbound variable' crash. Fix: use ${CFG_PYTHON_VENV:-app/.venv/bin/python3} at line 212.

<!-- note-id: lah9wfxd -->
<!-- timestamp: 2026-03-21T01:05:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed at plugins/dso/scripts/ci-status.sh line 212: changed `${repo_root:+$repo_root/$CFG_PYTHON_VENV}` to `${repo_root:+$repo_root/${CFG_PYTHON_VENV:-app/.venv/bin/python3}}`. RED confirmed: bash -u crash reproduced before fix. GREEN confirmed: function returns python3 without error after fix. All 8 existing ci-status tests pass.

<!-- note-id: 87jmeqai -->
<!-- timestamp: 2026-03-21T01:36:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: CFG_PYTHON_VENV default in ci-status.sh (commit 0f08614)
