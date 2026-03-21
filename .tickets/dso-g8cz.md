---
id: dso-g8cz
status: closed
deps: []
links: []
created: 2026-03-19T18:21:22Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-58
parent: dso-9xnr
---
# fix: compute-diff-hash.sh is not staging-invariant for new (untracked→staged) files


## Notes

<!-- note-id: sdd12zsg -->
<!-- timestamp: 2026-03-20T23:54:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: new files staged before review appear in git diff HEAD; hash is now stable between review and pre-commit since untracked processing removed

<!-- note-id: sci35q4u -->
<!-- timestamp: 2026-03-21T00:11:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: same root cause as dso-fqxu — untracked file hashing removed.

<!-- note-id: 7fytjg0g -->
<!-- timestamp: 2026-03-21T00:11:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: compute-diff-hash.sh staging invariance (commit 0ab58e5)
