---
id: dso-6x8o
status: closed
deps: []
links: []
created: 2026-03-22T00:00:28Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# Bug: record-test-status.sh allows re-recording with stale test results — hash updated without re-running tests


## Notes

<!-- note-id: mw0cb2ez -->
<!-- timestamp: 2026-03-22T00:00:47Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Observed Behavior

During the commit workflow, the orchestrator:
1. Ran tests and recorded test-gate-status (hash A)
2. Made code changes during the review resolution loop (code changed, hash now B)
3. Called record-test-status.sh again — it computed the new hash B and wrote 'passed' WITHOUT re-running the tests
4. The commit proceeded with hash B in test-gate-status, but the tests were only validated against hash A

This means record-test-status.sh trusts whatever the current diff hash is and stamps it as 'passed' based on a single test run, even if the code has changed since that run. The test gate checks that the hash matches, but it doesn't verify that the tests were actually run against the current hash.

## Root Cause

record-test-status.sh computes the current diff hash and writes it to test-gate-status with 'passed', but it does not compare the new hash against the hash from the actual test execution. If called after code changes (e.g., review fixes), it re-stamps without re-running.

## Expected Behavior

record-test-status.sh should either:
(a) Always re-run the associated tests before writing 'passed' (current behavior runs tests, but if called a second time after code changes, it should detect the hash mismatch and re-run), OR
(b) Track the hash at the time tests were run and refuse to write a new hash unless tests are re-executed

## Impact

The test gate can be satisfied without tests covering the actual committed code. This undermines the two-layer defense-in-depth: the gate checks hash consistency, but the recording step doesn't enforce test-to-hash correspondence on re-invocation.

## Reproduction

1. Stage files, run record-test-status.sh (records hash A)
2. Edit a staged file (hash changes to B)
3. Run record-test-status.sh again (records hash B with 'passed' — no tests re-run if the associated test files haven't changed)

