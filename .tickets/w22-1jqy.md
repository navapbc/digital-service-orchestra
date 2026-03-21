---
id: w22-1jqy
status: closed
deps: []
links: []
created: 2026-03-21T04:00:04Z
type: bug
priority: 3
assignee: Joe Oakhart
parent: w22-ns6l
---
# Bug: test-discover-agents.sh flaky in full suite — passes in isolation

test-discover-agents.sh failed once during full suite run (bash tests/run-all.sh) but passed when run in isolation (bash tests/scripts/test-discover-agents.sh). Likely a test ordering or environment leak issue. Observed 2026-03-21 during sprint session worktree-20260320-200821. 1 occurrence so far — monitor for recurrence.


## Notes

**2026-03-21T16:12:02Z**

Fixed: replaced hardcoded /tmp/test_discover_stderr.txt with isolated tmpdir path (commit b588386)
