---
id: w21-j2cc
status: open
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
