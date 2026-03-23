---
id: w22-9wrx
status: closed
deps: []
links: []
created: 2026-03-22T07:50:26Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: w22-ns6l
---
# Bug: test-merge-to-main-ucq2.sh flakes in full suite (race condition in temp dir cleanup)

test-merge-to-main-ucq2.sh fails 1 out of 22 times in the full suite (tests/run-all.sh parallel execution) but passes 22/22 when run individually. Root cause candidate: race condition in temp dir cleanup during parallel test execution.


## Notes

**2026-03-22T07:51:12Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.

<!-- note-id: s3rno2xn -->
<!-- timestamp: 2026-03-22T22:36:46Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: PID-suffixed BRANCH in test 15 prevents /tmp state file race

<!-- note-id: rhyieeyr -->
<!-- timestamp: 2026-03-22T22:36:47Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: PID-suffixed BRANCH prevents temp dir race condition
