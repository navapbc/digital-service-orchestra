---
id: dso-b25k
status: closed
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

## ACCEPTANCE CRITERIA

- [ ] hook_bug_close_guard function removed from pre-bash-functions.sh
  Verify: { grep -q 'hook_bug_close_guard' plugins/dso/hooks/lib/pre-bash-functions.sh; test $? -ne 0; }
- [ ] hook_bug_close_guard call removed from dispatchers/pre-bash.sh
  Verify: { grep -q 'hook_bug_close_guard' plugins/dso/hooks/dispatchers/pre-bash.sh; test $? -ne 0; }
- [ ] closed-parent-guard.sh deleted
  Verify: test ! -f plugins/dso/hooks/closed-parent-guard.sh
- [ ] bug-close-guard.sh deleted
  Verify: test ! -f plugins/dso/hooks/bug-close-guard.sh
- [ ] Bash syntax validation passes
  Verify: bash -n plugins/dso/hooks/lib/pre-bash-functions.sh && bash -n plugins/dso/hooks/dispatchers/pre-bash.sh

**2026-03-23T20:01:52Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T20:02:18Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T20:02:22Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-23T20:11:24Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T20:11:29Z**

CHECKPOINT 5/6: Validation passed ✓ — all 5 ACs pass; syntax check clean; test-pre-bash-dispatcher.sh has 1 pre-existing failure (test_pre_bash_dispatcher_non_exit2_codes_pass_through) that predates this batch

**2026-03-23T20:11:42Z**

CHECKPOINT 6/6: Done ✓ — PRE-T6 verified: tk close routes through cmd_status (writes .tickets/ flat files, NOT ticket-transition.sh). Enforcement gap for tk close is acceptable — tk is being removed in story w21-gy45.
