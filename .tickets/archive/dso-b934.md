---
id: dso-b934
status: closed
deps: []
links: []
created: 2026-03-19T23:52:29Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-d72c
---
# Fix: test-cascade-breaker.sh is flaky — timing-sensitive failure in full suite run


## Notes

<!-- note-id: l1bwlxml -->
<!-- timestamp: 2026-03-19T23:52:37Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Standalone error: test-cascade-breaker.sh is flaky — 1 failure observed in full suite run, 0 failures on 2 re-runs.

Failure is timing-sensitive: test passes consistently when run standalone but occasionally fails during the full parallel suite run (likely due to shared state or race condition).

Observed: 1 fail in suite run, 0 fails on 2 separate re-runs.

Fix: investigate for shared state (e.g., tmp files, global counters) that may be polluted by parallel test execution, and add isolation for that state in the test.

**2026-03-20T00:09:50Z**

Fix: Replaced shared /tmp/claude-cascade-${WT_HASH} STATE_DIR (based on real REPO_ROOT) with a unique mktemp -d fake git repo. The test now runs the hook from within that fake git root so git rev-parse returns a unique path, producing an isolated STATE_DIR per test run. Added trap for cleanup on EXIT. Also resolved macOS symlink issue: FAKE_ROOT is resolved via git rev-parse after init to match what the hook sees (/private/var/... vs /var/...). Verified: 8/8 pass standalone and 3 parallel runs all pass.

<!-- note-id: u52gumnx -->
<!-- timestamp: 2026-03-20T00:32:02Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: isolated test-cascade-breaker.sh with unique temp dir and fake git repo

<!-- note-id: sri6oj84 -->
<!-- timestamp: 2026-03-20T00:32:03Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: test isolation via mktemp + fake git repo in test-cascade-breaker.sh (commit 546b453)
