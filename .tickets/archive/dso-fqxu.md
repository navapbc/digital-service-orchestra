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

<!-- note-id: xcy8md5v -->
<!-- timestamp: 2026-03-21T00:11:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: removed untracked file hashing from compute-diff-hash.sh. Tests: test-compute-diff-hash-staging-invariance.sh (14/14).

<!-- note-id: 3itax9qb -->
<!-- timestamp: 2026-03-21T00:11:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: compute-diff-hash.sh staging invariance (commit 0ab58e5)
