---
id: dso-nthb
status: open
deps: []
links: []
created: 2026-03-20T00:40:43Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-d72c
---
# Fix: test-behavioral-equivalence-allowlist.sh TIMEOUT (30s) in full suite


## Notes

<!-- note-id: ivka3dhm -->
<!-- timestamp: 2026-03-20T00:40:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

TIMEOUT at 30s during full parallel hook suite. Passes standalone. Similar to dso-dcau (isolation timeout) — may need increased timeout in hook test runner.

<!-- note-id: s0twavle -->
<!-- timestamp: 2026-03-20T00:40:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

SAFEGUARDED: fix may require editing tests/hooks/ test runner
