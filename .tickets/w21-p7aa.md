---
id: w21-p7aa
status: closed
deps: []
links: []
created: 2026-03-21T01:34:30Z
type: epic
priority: 1
assignee: Joe Oakhart
---
# Batched Test Enforcement: Hook Interception + Structured Output Protocol


## Notes

**2026-03-21T01:34:42Z**


## Context

Engineers using DSO-managed workflows ship changes with unvalidated test suites because agents silently abandon test runs — either by running raw test commands that hit the ~73s tool timeout (Pattern B) or by invoking test-batched.sh once and treating partial output as failure instead of continuing (Pattern A). This leads to regressions discovered post-merge and wasted agent cycles across every workflow — sprint, commit, fix-bug, and manual sessions. After this epic, engineers will no longer need to manually detect or restart incomplete test runs — the hook and structured output protocol handle both enforcement and continuation prompting automatically.

## Matching Contract

A Bash tool input matches a configured blocked command if, after splitting on shell operators (&&, ||, ;, |) and stripping all leading cd <path> && segments (zero or more) from each resulting segment, any segment equals a configured commands.test_unit or commands.test_e2e value from dso-config.conf verbatim as a complete token sequence (not a substring). Commands with additional arguments appended after the configured value do not match.

## Structured Action-Required Block

A block written to stdout by the emitting component. Format:

ACTION REQUIRED: tests incomplete (<completed>/<total> passed)
RUN: <command>
DO NOT proceed without completing all test batches.

When emitted by the PreToolUse hook (blocked command): RUN: always contains validate.sh --ci.
When emitted by test-batched.sh or validate.sh (partial run): RUN: contains the dynamic resume command from the test-batched.sh state file.

## Success Criteria

1. A PreToolUse hook blocks execution of commands matching the Matching Contract. The hook exits non-zero before the test runner process spawns and emits the Structured Action-Required Block with RUN: validate.sh --ci. Verification: a test asserting make test-unit-only produces the block and zero pytest output; a test asserting make test-unit-only-fast is not intercepted.
2. test-batched.sh itself emits the Structured Action-Required Block when exiting with incomplete tests. validate.sh itself emits the block when exiting with code 2 (tests pending). Both scripts are the emitting component — no hook or wrapper involvement. Verification: output of a partial validate.sh run matches the block format exactly.
3. CLAUDE.md and SUB-AGENT-BOUNDARIES.md are updated in a one-time edit: configured broad test commands added to Never Do These list, quick-reference/example usage replaced with validate.sh. Verification: for make test-unit-only and make test-e2e, grep -n in these files returns zero matches outside lines between ### Never Do These and the next ### heading.
4. The hook reads blocked commands exclusively from dso-config.conf — no hardcoded test command strings in hook source. Verification: hook source contains zero literal test command strings.
5. Commands not matching the Matching Contract pass through unblocked. Verification: make test-unit-only path/to/test.py (additional arguments) not intercepted; pytest tests/unit/test_foo.py (not a configured command) not intercepted.
6. Hook telemetry JSONL records intercepted commands as blocked_test_command events (distinct from exit-144). Verification: test asserts blocked command produces blocked_test_command telemetry entry. Post-deploy health signal (no merge gate): exit-144 entries for test commands drop to zero across 3 sessions with code changes.

## Dependencies

None (commands.test_unit/commands.test_e2e already exist in dso-config.conf). Coordination dependency (non-blocking): dso-ppwp (test gate enforcement) shares hook infrastructure.

## Approach

Config-driven PreToolUse hook interception (blocks raw broad test commands before execution) combined with structured output protocol updates to test-batched.sh and validate.sh (makes partial-result continuation unmissable). One-time doc edit to remove counterproductive references to prohibited commands.

