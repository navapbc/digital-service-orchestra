---
id: dso-fqxu
status: closed
deps: []
links: []
created: 2026-03-19T16:58:19Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-63
parent: dso-9xnr
---
# fix: compute-diff-hash.sh hash mismatch when untracked temp test fixtures exist during review


## Notes

<!-- note-id: rp5yitoa -->
<!-- timestamp: 2026-03-20T23:54:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: removed untracked file processing from compute-diff-hash.sh; hash now only covers staged+tracked changes, excluding temp fixtures
