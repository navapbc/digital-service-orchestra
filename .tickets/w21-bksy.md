---
id: w21-bksy
status: closed
deps: []
links: []
created: 2026-03-20T19:40:10Z
type: bug
priority: 4
assignee: Joe Oakhart
parent: w22-ns6l
---
# Fix: overly broad grep assertion in test_discovers_associated_tests in test-record-test-status.sh


## Notes

**2026-03-22T07:51:12Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.

<!-- note-id: mlc31ix9 -->
<!-- timestamp: 2026-03-22T15:28:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: mechanical (grep assertion is overly broad — should check tested_files field in test-gate-status specifically). Fix: replace grep -rq 'test_foo' with check for 'tested_files=.*test_foo' in the test-gate-status file.

<!-- note-id: hw5epbso -->
<!-- timestamp: 2026-03-22T15:40:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: replaced grep -rq 'test_foo' ARTIFACTS_1/ with grep -q 'tested_files=.*test_foo' ARTIFACTS_1/test-gate-status in test_discovers_associated_tests
