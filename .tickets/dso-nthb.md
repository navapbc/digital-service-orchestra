---
id: dso-nthb
status: closed
deps: []
links: []
created: 2026-03-20T00:40:43Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-d72c
---
# Fix: test-behavioral-equivalence-allowlist.sh TIMEOUT (30s) in full suite


## Notes

<!-- note-id: ivka3dhm -->
<!-- timestamp: 2026-03-20T00:40:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

TIMEOUT at 30s during full parallel hook suite. Passes standalone. Similar to dso-dcau (isolation timeout) — may need increased timeout in hook test runner.

<!-- note-id: s0twavle -->
<!-- timestamp: 2026-03-20T00:40:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

SAFEGUARDED: fix may require editing tests/hooks/ test runner

<!-- note-id: enw57w75 -->
<!-- timestamp: 2026-03-20T00:44:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fix: increased TEST_TIMEOUT from 30 to 120 in run-hook-tests.sh (before sourcing suite-engine.sh), matching the same fix applied to run-script-tests.sh for dso-dcau. test-behavioral-equivalence-allowlist.sh takes ~13s standalone; 30s is insufficient under CPU contention in the full parallel suite.

<!-- note-id: m271ypuv -->
<!-- timestamp: 2026-03-20T00:48:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: increased TEST_TIMEOUT to 120s in tests/hooks/run-hook-tests.sh to prevent timeout under CPU contention in parallel suite
