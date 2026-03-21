---
id: w21-qsu5
status: closed
deps: []
links: []
created: 2026-03-21T03:36:06Z
type: bug
priority: 1
assignee: Joe Oakhart
parent: w22-ns6l
---
# Bug: cascade-circuit-breaker ERR trap swallows exit-2 on CI Linux (6 test failures)


## Notes

**2026-03-21T03:36:13Z**

The ERR trap in cascade-circuit-breaker.sh (and its function version in pre-edit-write-functions.sh) fires unexpectedly on Linux CI, converting intentional exit-2 blocks into exit-0 (allow). Affects test-cascade-breaker.sh (2 fails) and test-pre-edit-write-dispatcher.sh (4 fails). Enhanced logging added to ERR trap ($BASH_COMMAND to /tmp/) — check next CI run output for diagnostics. Tests pass on macOS.

**2026-03-21T05:14:08Z**

Fixed: /tmp/* passthrough pattern in cascade-circuit-breaker.sh and pre-edit-write-functions.sh was too broad on Linux CI. Replaced bare /tmp/* with conditional that excludes files inside the current worktree. Added test for Linux CI scenario. Commit 71c48bf.
