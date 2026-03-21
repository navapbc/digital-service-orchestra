---
id: w21-wlhw
status: closed
deps: []
links: []
created: 2026-03-20T00:10:05Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-9xnr
---
# test-pre-edit-write-dispatcher.sh uses real REPO_ROOT for cascade STATE_DIR — same isolation anti-pattern as dso-b934


## Notes

**2026-03-20T00:10:09Z**

Same anti-pattern as dso-b934 (test-cascade-breaker.sh). tests/hooks/test-pre-edit-write-dispatcher.sh computes _CASCADE_STATE_DIR from the real REPO_ROOT hash. During parallel suite runs, this can collide with the real cascade counter or other tests. Fix: use a unique mktemp -d fake git repo, run hook from within it, and resolve path via git rev-parse to handle macOS symlinks (/private/var/... vs /var/...). See dso-b934 for the reference fix pattern.

<!-- note-id: sg6ouq79 -->
<!-- timestamp: 2026-03-21T00:17:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: tests/hooks/test-pre-edit-write-dispatcher.sh now uses FAKE_ROOT with a minimal git repo for STATE_DIR isolation, all dispatcher invocations run via cd _FAKE_ROOT

<!-- note-id: 1mgtgp8l -->
<!-- timestamp: 2026-03-21T00:24:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: test isolation with _FAKE_ROOT (commit 6badeb4)
