---
id: dso-qlgq
status: closed
deps: []
links: []
created: 2026-03-20T22:51:51Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# validate-phase.sh runs tests directly without test-batched.sh — same timeout anti-pattern as w21-ae0s

## Problem

validate-phase.sh runs CMD_TEST_UNIT via eval directly (same anti-pattern as w21-ae0s fixed in validate.sh). This means validate-phase.sh calls also hit the 73s Claude tool timeout ceiling when test suites exceed ~50s.

Affected: all three test_output calls in validate-phase.sh run tests without test-batched.sh wrapping.

## Fix
Integrate test-batched.sh into validate-phase.sh for the test step, similar to how it was done in validate.sh. Use VALIDATE_TEST_STATE_FILE / VALIDATE_TEST_BATCHED_SCRIPT env vars for consistency.

## Related
Discovered while fixing w21-ae0s (validate.sh timeout anti-pattern).


## Notes

<!-- note-id: 4uqdd7fy -->
<!-- timestamp: 2026-03-21T01:05:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: behavioral, Score: 2 (BASIC). Root cause: phase_auto_fix, phase_post_batch, and phase_tier_transition all run CMD_TEST_UNIT via raw eval, bypassing test-batched.sh. Fix: extract a run_test_batched() helper in validate-phase.sh that mirrors validate.sh's run_test_check() pattern — calls test-batched.sh when available, falls back to direct eval. Use VALIDATE_TEST_STATE_FILE / VALIDATE_TEST_BATCHED_SCRIPT env vars for overridability in tests.

<!-- note-id: puampc20 -->
<!-- timestamp: 2026-03-21T01:15:52Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: validate-phase.sh now uses test-batched.sh via run_test_batched() helper in all three phase functions (phase_auto_fix, phase_post_batch, phase_tier_transition); falls back to direct eval when script is absent; PENDING exit code (2) propagated on NEXT: output. Tests: 21/21 pass. Committed in 0f08614.

<!-- note-id: 67yv85d6 -->
<!-- timestamp: 2026-03-21T01:36:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: validate-phase.sh test-batched integration (commit 0f08614)
