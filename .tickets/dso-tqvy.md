---
id: dso-tqvy
status: closed
deps: []
links: []
created: 2026-03-19T16:58:37Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-67
parent: dso-9xnr
---
# fix: worktree-sync-from-main.sh crashes with CFG_PYTHON_VENV unbound variable when config key is absent


## Notes

<!-- note-id: bp72ypsd -->
<!-- timestamp: 2026-03-21T00:42:01Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: added ${CFG_PYTHON_VENV:-app/.venv/bin/python3} default in worktree-sync-from-main.sh line 36; regression test added as Test 16 in test-worktree-sync-from-main-fallback.sh
