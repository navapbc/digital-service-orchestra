---
id: dso-s16u
status: open
deps: []
links: []
created: 2026-03-23T00:02:55Z
type: task
priority: 2
assignee: Joe Oakhart
---
# bug Test gate blocks merge commits due to stale diff hash from incoming-only changes


## Notes

<!-- note-id: xboa2li9 -->
<!-- timestamp: 2026-03-23T00:03:03Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Root cause: pre-commit-test-gate.sh lacks MERGE_HEAD-aware filtering that the review gate already has. During a merge commit, the test gate computes its diff hash over ALL staged changes including incoming-only changes from main, causing a hash mismatch with the pre-recorded test status. Fix: implement the same MERGE_HEAD detection and incoming-only file exclusion logic from pre-commit-review-gate.sh (line ~193) in pre-commit-test-gate.sh. The test gate should only require test status for files the worktree branch actually modified, not files that changed only on main.
