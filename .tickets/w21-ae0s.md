---
id: w21-ae0s
status: in_progress
deps: []
links: []
created: 2026-03-19T04:51:48Z
type: bug
priority: 1
assignee: Joe Oakhart
parent: dso-9xnr
---
# Validation gate times out on projects with >50s test suites — incorporate test-batched or split validate.sh

## Problem

validate.sh --ci runs all checks (skill-refs, issues, tests, lint) in a single process. When the test suite exceeds ~50 seconds (well within the 73-second Claude tool timeout ceiling), the entire validation gate fails with exit 144.

test-batched.sh was built specifically to handle this — it wraps long commands in a time-bounded loop with state file resumption. But validate.sh does not use test-batched.sh for its test step, so the solution doesn't reach the pain point.

## Impact

Every sprint, debug-everything, and manual validation invocation hits this friction. The orchestrator must repeatedly retry or work around the timeout, wasting context and time. This is the #1 source of sprint initialization friction.

## Possible Mitigations

1. **Integrate test-batched.sh into validate.sh**: Make validate.sh use test-batched.sh for the test step, writing progress to state file and allowing incremental completion across multiple invocations.
2. **Split validate.sh into independent checks**: Allow each check (skill-refs, issues, tests, lint) to run independently with its own state file. The orchestrator runs them one at a time, each within the timeout ceiling.
3. **Validate.sh state file awareness**: validate.sh checks for an existing test-batched state file and reuses results if the tests already passed in this session.
4. **Timeout-aware internal chunking**: validate.sh detects when it's running inside Claude Code (env var) and self-limits each step to ~45 seconds, writing partial results.

## Acceptance Criteria

- validate.sh --ci completes successfully on projects with test suites up to 120 seconds
- No single Bash tool call during validation exceeds the 73-second timeout ceiling
- validate.sh reuses test results from the current session when available
- Incremental progress is preserved across multiple invocations

