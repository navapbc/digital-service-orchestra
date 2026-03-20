---
id: dso-hdgl
status: closed
deps: []
links: []
created: 2026-03-20T00:40:44Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-d72c
---
# Fix: test-merge-to-main-portability.sh 2 failures (8 pass, 2 fail)


## Notes

<!-- note-id: o0y3gv20 -->
<!-- timestamp: 2026-03-20T00:40:55Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

2 of 10 assertions fail in test-merge-to-main-portability.sh. Pre-existing — not caused by batch 1 fixes.

**2026-03-20T00:49:04Z**

Root cause confirmed: test-merge-to-main-portability.sh takes ~8.7s standalone. Under heavy parallel load (145+ concurrent processes) with old TEST_TIMEOUT=30 in run-hook-tests.sh, CPU contention caused the test to exceed the 30s budget, producing 2 spurious assertion failures. Same root cause as dso-nthb and dso-dcau. Fix already applied: TEST_TIMEOUT raised to 120 in tests/hooks/run-hook-tests.sh (committed as part of dso-nthb fix). Tests pass 10/10 in 3 consecutive standalone runs and 964/964 in full suite. No additional code change required.
