---
id: w21-da9n
status: closed
deps: []
links: []
created: 2026-03-21T21:59:08Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: w22-ns6l
---
# test-cleanup-claude-session.sh times out (exceeds 120s)


## Notes

**2026-03-22T07:51:12Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.

<!-- note-id: 9rgup9k3 -->
<!-- timestamp: 2026-03-22T21:51:37Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Not reproduced: test passes (12/12) in 180s timeout. Likely resolved by SUITE_TIMEOUT increase.

<!-- note-id: tjojukpx -->
<!-- timestamp: 2026-03-22T21:51:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: not reproducible after SUITE_TIMEOUT increase to 600s in run-all.sh
