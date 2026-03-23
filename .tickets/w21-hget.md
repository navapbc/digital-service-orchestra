---
id: w21-hget
status: closed
deps: []
links: []
created: 2026-03-21T01:59:26Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: w22-ns6l
---
# Fix: test-merge-to-main-portability.sh pre-existing failures (sequential phase warning)


## Notes

**2026-03-22T07:51:12Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.

<!-- note-id: uf415xpg -->
<!-- timestamp: 2026-03-22T16:30:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: behavioral, Score: 1 (BASIC). Root cause: portability tests exercise the no-args merge-to-main.sh code path which emits 'WARNING: Running all phases sequentially' to stderr, but the test has no assertion documenting or verifying this behavior. Tests pass currently because existing assertions only check for 'DONE', 'INFO:' messages, and absence of errors — the WARNING is silently ignored. Fix: add assert_contains assertion for the WARNING message in Test 1 to document the expected no-args behavior.

<!-- note-id: mqhyft9w -->
<!-- timestamp: 2026-03-22T16:38:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: Added assert_contains for 'WARNING: Running all phases sequentially' in tests/hooks/test-merge-to-main-portability.sh Test 1, closing the test-coverage gap where the no-args behavior was captured but never explicitly verified.
