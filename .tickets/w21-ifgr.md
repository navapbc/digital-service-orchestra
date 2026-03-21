---
id: w21-ifgr
status: closed
deps: []
links: []
created: 2026-03-21T01:41:06Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-p7aa
---
# As a DSO practitioner, broad test commands are blocked before execution with a config-driven redirect to validate.sh

## Description

**What**: A PreToolUse hook that intercepts configured broad test commands and blocks them before the test runner process spawns, emitting a structured action-required block redirecting to validate.sh
**Why**: Prevents Pattern B — agents running raw test commands that hit the ~73s tool timeout and then giving up
**Scope**:
- IN: Hook implementation, config-driven matching contract (reads commands.test_unit and commands.test_e2e from dso-config.conf), pass-through for non-matching commands, blocked_test_command telemetry events
- OUT: Modifying test-batched.sh or validate.sh output (sibling story); documentation changes (sibling story)

## Done Definitions

- When this story is complete, running a configured broad test command (e.g., make test-unit-only) via the Bash tool results in a non-zero hook exit and the Structured Action-Required Block — the test runner process never spawns
  ← Satisfies: "A PreToolUse hook blocks execution of commands matching the Matching Contract"
- When this story is complete, the hook reads blocked command patterns exclusively from dso-config.conf with zero hardcoded test command strings in hook source
  ← Satisfies: "The hook reads blocked commands exclusively from dso-config.conf"
- When this story is complete, commands not matching the Matching Contract (commands with additional path arguments, commands not in config) pass through unblocked
  ← Satisfies: "Commands not matching the configured blocked-command contract pass through unblocked"
- When this story is complete, intercepted commands are recorded as blocked_test_command events in hook telemetry JSONL, distinct from exit-144 events
  ← Satisfies: "Hook telemetry JSONL records intercepted commands as blocked_test_command events"
- When this story is complete, the RUN: line in the Structured Action-Required Block includes the absolute path to validate.sh (resolved from CLAUDE_PLUGIN_ROOT at runtime)
  ← Satisfies: "emits the Structured Action-Required Block with RUN: validate.sh --ci"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Performance] Hook runs on every Bash tool call — must have fast early-exit guard (keyword check) to avoid adding latency to non-test commands
- [Testing] Shell command-matching logic has edge cases (quoted strings, multi-segment pipelines, cd-prefix stripping) — thorough unit tests needed
- [Reliability] False positive interception blocks legitimate commands — matching contract precision is safety-critical; verify that validate.sh and test-batched.sh wrapper invocations do not match the blocking contract
- [Maintainability] Hook must stay in sync with dso-config.conf key names — if keys are renamed, hook breaks silently


## Notes

**2026-03-21T02:01:10Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
