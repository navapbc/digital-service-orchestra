---
id: w20-fxpu
status: closed
deps: []
links: []
created: 2026-03-21T17:41:51Z
type: bug
priority: 3
assignee: Joe Oakhart
parent: w22-ns6l
---
# Fix test_auto_detect_main_worktree_via_git_list macOS path comparison bug


## Notes

**2026-03-21T17:42:01Z**

Test 12 in tests/scripts/test-ticket-init.sh (test_auto_detect_main_worktree_via_git_list) fails on macOS due to /var -> /private/var symlink resolution. The test compares os.path.realpath(symlink) against raw mktemp-generated path ($main_repo/.tickets-tracker). On macOS, mktemp returns /var/folders/... but os.path.realpath always resolves /var to /private/var. The symlink implementation is correct; the test's expected_target needs os.path.realpath() applied to it for the comparison to work on macOS. Fix: in test 12, change expected_target to use python3 os.path.realpath(main_repo + '/.tickets-tracker') instead of the raw path.

**2026-03-22T07:51:11Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.

<!-- note-id: lpdwuys4 -->
<!-- timestamp: 2026-03-22T16:22:40Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Already fixed in commit 95bf595 — os.path.realpath() applied to expected_target in test_auto_detect_main_worktree_via_git_list; all 20 tests pass
