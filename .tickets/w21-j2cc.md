---
id: w21-j2cc
status: closed
deps: []
links: []
created: 2026-03-20T01:05:43Z
type: bug
priority: 3
assignee: Joe Oakhart
parent: dso-9xnr
---
# BUG: AC4 check in w21-cu3r incompatible with assert.sh output format


## Notes

**2026-03-20T01:05:54Z**

AC4 in w21-cu3r checks: bash tests/scripts/test-dso-setup.sh 2>&1 | grep -c 'PASS' | awk '{exit ($1 < 25)}'. The assert.sh library only prints PASS in the summary line (PASSED: 31 FAILED: 4), so grep -c returns 1 (one line), not the actual pass count 31. The awk check fails because 1 < 25. This AC was likely written expecting per-assertion PASS output (e.g. 'test_foo ... PASS'). Either the AC check needs fixing or assert.sh needs to emit per-test PASS lines.

<!-- note-id: srgin2mz -->
<!-- timestamp: 2026-03-21T01:42:10Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: Changed AC4 verify command in .tickets/archive/w21-cu3r.md from 'grep -c PASS | awk $1 < 25' (which returns line count=1) to 'awk /PASSED:/ $2 < 25' which extracts the actual pass count from the summary line format 'PASSED: N  FAILED: N'.

<!-- note-id: 2deuitu7 -->
<!-- timestamp: 2026-03-21T01:43:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: Changed AC4 verify in .tickets/archive/w21-cu3r.md from 'grep -c PASS | awk $1 < 25' to 'awk /PASSED:/ $2 < 25' to correctly parse assert.sh summary format
