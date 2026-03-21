---
id: dso-62u0
status: closed
deps: []
links: []
created: 2026-03-19T16:57:49Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-57
parent: dso-9xnr
---
# fix: merge-to-main.sh sync phase fails when .tickets/.index.json has uncommitted local changes


## Notes

<!-- note-id: lrbew7sb -->
<!-- timestamp: 2026-03-20T23:54:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: stash .tickets/.index.json in _worktree_sync_from_main before git merge origin/main to prevent 'would be overwritten by merge' failure. Restore stash after sync. Test added: test_sync_stashes_uncommitted_index_json in test-worktree-sync-from-main-fallback.sh

<!-- note-id: ilswsdv2 -->
<!-- timestamp: 2026-03-21T00:01:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: stash .tickets/.index.json in _worktree_sync_from_main before git merge origin/main (worktree-sync-from-main.sh) — commit e130713
