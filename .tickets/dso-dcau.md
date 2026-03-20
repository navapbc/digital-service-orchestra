---
id: dso-dcau
status: in_progress
deps: []
links: []
created: 2026-03-19T23:51:57Z
type: bug
priority: 1
assignee: Joe Oakhart
parent: dso-d72c
---
# Fix: isolation tests timeout during full parallel suite run due to CPU contention (2 tests)


## Notes

<!-- note-id: iiavl1ss -->
<!-- timestamp: 2026-03-19T23:52:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Cluster 2: Parallel execution timeouts in isolation tests.

Root cause: tests/scripts/run-script-tests.sh runs 145+ concurrent test processes, causing CPU contention. Both failing tests pass individually in <10s but time out (>60s) during full suite parallel execution.

Failing tests:
- test-isolation-check.sh: TIMEOUT (exceeded 60s) — passes when run standalone
- test-isolation-rule-no-direct-os-environ.sh: TIMEOUT (exceeded 60s) — passes when run standalone

Fix options: (1) reduce parallelism in run-script-tests.sh (e.g., --jobs N flag with bounded concurrency), (2) add timeout exemptions for known-slow tests, or (3) move heavy isolation tests to a separate sequential suite.
