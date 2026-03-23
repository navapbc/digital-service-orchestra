---
id: dso-b25k
status: open
deps: [dso-jyob, dso-1459, dso-9p30]
links: []
created: 2026-03-23T17:34:49Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-k4sw
---
# Remove hook_bug_close_guard and delete closed-parent-guard.sh


## Notes

**2026-03-23T17:35:42Z**

## Description
Remove old hook-based guards:
1. Remove hook_bug_close_guard function from pre-bash-functions.sh (lines 498-583)
2. Remove its call from dispatchers/pre-bash.sh (line 102)
3. Remove its entry from the function table comment (line 17)
4. Delete closed-parent-guard.sh (dead code — not registered in plugin.json)
5. Delete bug-close-guard.sh (thin wrapper calling hook_bug_close_guard)
6. Update tests/hooks/test-pre-bash-functions-ticket-guards.sh — remove hook-specific tests
7. Clean .test-index RED markers for removed test entries
8. Check plugins/dso/hooks/rollback/settings-pre-task2.json for bug-close-guard references

Pre-T6 verification: confirm that tk close routes through tk cmd_status (writes .tickets/ flat files, NOT ticket-transition.sh). The enforcement gap for tk close is acceptable — tk is being removed in story w21-gy45 (cleanup). Document this in the commit message.

