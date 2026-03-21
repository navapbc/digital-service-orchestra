---
id: dso-2e99
status: open
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
