---
id: dso-qlgq
status: open
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

