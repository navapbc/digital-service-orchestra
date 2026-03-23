---
id: dso-y1hq
status: closed
deps: []
links: []
created: 2026-03-22T21:45:09Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: w22-ns6l
---
# run-all.sh SUITE_TIMEOUT=180 too short — causes false test FAIL

Default SUITE_TIMEOUT=180 in tests/run-all.sh is too short for script tests under CPU contention. gtimeout kills the script test runner at 180s (exit 124). SUITE_TIMEOUT=600 fixes it. Root cause: script test suite takes >180s when CPU-contended by concurrent hook tests.


## Notes

<!-- note-id: fn61aaoe -->
<!-- timestamp: 2026-03-22T22:19:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: SUITE_TIMEOUT increased from 180s to 600s

<!-- note-id: s89lq2vw -->
<!-- timestamp: 2026-03-22T22:19:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: run-all.sh SUITE_TIMEOUT increased from 180s to 600s
