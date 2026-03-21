---
id: dso-ptct
status: open
deps: []
links: []
created: 2026-03-21T23:55:41Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# Bug: stat -f || stat -c fallback pattern broken on Linux — stat -f succeeds with wrong semantics


## Notes

<!-- note-id: w3rqlnay -->
<!-- timestamp: 2026-03-21T23:55:53Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: mechanical. Root cause: stat -f '%m' on Linux does not fail — it returns filesystem metadata (block counts, inode info). The || fallback to stat -c '%Y' never triggers. Fix: use uname-based OS detection (same pattern as health-check.sh _file_mtime). Fixed in 5 locations across 4 files: test-compact-sync-precondition.sh, test-sync-roundtrip.sh, worktree-cleanup.sh, REVIEW-WORKFLOW.md. Test gate gap: the test gate correctly requires test-compact-sync-precondition.sh for changes to ticket-compact.sh, but the stat bug was in the TEST file itself (not the source file it covers). The test gate can't catch bugs in tests that only manifest on a different OS — this is a fundamental limitation addressed by CI, not the gate.
