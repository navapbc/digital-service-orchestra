---
id: dso-kv4p
status: closed
deps: []
links: []
created: 2026-03-19T18:22:18Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-68
parent: dso-9xnr
---
# fix: merge-to-main.sh push phase fails with retry_with_backoff: command not found


## Notes

<!-- note-id: d5aiz5bc -->
<!-- timestamp: 2026-03-20T23:54:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: defined retry_with_backoff inline in merge-to-main.sh as a fallback guarded by 'if \! type retry_with_backoff', so _phase_push works even when deps.sh is absent. Test added: test_retry_with_backoff_defined_inline_in_merge_script in test-retry-with-backoff.sh

<!-- note-id: 840cyig2 -->
<!-- timestamp: 2026-03-21T00:01:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: define retry_with_backoff inline in merge-to-main.sh as fallback guarded by type-check — commit e130713
