---
id: dso-pa2n
status: in_progress
deps: []
links: []
created: 2026-03-19T23:52:49Z
type: bug
priority: 3
assignee: Joe Oakhart
parent: dso-d72c
---
# Fix: tests/run-all.sh line 231 unbound variable $1 in combined summary formatting function


## Notes

<!-- note-id: kpu8tz0u -->
<!-- timestamp: 2026-03-19T23:52:57Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Standalone error: tests/run-all.sh line 231 — cosmetic bug.

Error: `$1: unbound variable` in combined summary formatting function.

Impact: cosmetic only — does not affect test pass/fail counting. The error appears during combined summary output formatting but does not change any test result.

Fix: add a default value for $1 in the combined summary formatting function at line 231, e.g., ${1:-} or guard with [ -n "$1" ] check.
