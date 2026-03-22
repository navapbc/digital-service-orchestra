---
id: dso-sfoc
status: closed
deps: []
links: []
created: 2026-03-21T23:32:27Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# Bug: pre-commit test gate times out on large ticket-only commits (no allowlist filtering)


## Notes

<!-- note-id: 1tgvs3z5 -->
<!-- timestamp: 2026-03-21T23:32:34Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: mechanical. The test gate runs fuzzy matching on all staged files including non-reviewable files (.tickets/**, images, docs). With 294 ticket archive files staged, this exceeds the 10s pre-commit timeout. Fix: filter staged files through review-gate-allowlist.conf before fuzzy matching, same as the review gate does.

<!-- note-id: aihhn7qs -->
<!-- timestamp: 2026-03-21T23:35:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: added allowlist filtering and fail-open timeout trap to pre-commit-test-gate.sh
