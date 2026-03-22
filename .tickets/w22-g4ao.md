---
id: w22-g4ao
status: open
deps: []
links: []
created: 2026-03-22T07:50:28Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: w22-ns6l
---
# Bug: test-check-script-writes.sh flakes in full suite (shfmt availability race)

test-check-script-writes.sh fails 2 out of 5 times in the full suite (tests/run-all.sh parallel execution) but passes individually (5/0 with skips). Root cause candidate: shfmt availability race during parallel test execution.


## Notes

**2026-03-22T07:51:12Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.
