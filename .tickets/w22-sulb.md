---
id: w22-sulb
status: open
deps: [w22-uqfn]
links: []
created: 2026-03-20T14:53:27Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-ppwp
---
# As a developer, I cannot bypass the test gate through alternative commit methods

## Description

**What**: Layer 2 bypass prevention for the test gate — extend the PreToolUse sentinel to block direct writes to test-status/exemption files, plus a two-layer integration test.
**Why**: Without Layer 2, an agent could use the no-verify flag or write directly to the test-status file to circumvent the gate. Defense in depth requires both layers.
**Scope**:
- IN: Extend bypass sentinel to block direct writes to test-status and exemption file paths, synthetic two-layer integration test (failing test blocked by Layer 1; same attempt with no-verify flag blocked by Layer 2)
- OUT: The existing bypass blocking (no-verify, plumbing, core.hooksPath=) is already in review-gate-bypass-sentinel.sh — this story only adds test-gate-specific patterns

## Done Definitions

- When this story is complete, a Bash tool call that writes directly to the test-status or exemption file paths is blocked by the PreToolUse hook with a clear error message
  ← Satisfies: "Bypass attempts (direct writes to the test-status or exemption files) are intercepted and blocked at the PreToolUse layer"
- When this story is complete, a synthetic commit with a failing associated test is blocked by Layer 1, and the same attempt using the no-verify flag is blocked by Layer 2
  ← Satisfies: "A test suite validates both layers"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Security] Audit existing review-gate-bypass-sentinel.sh for completeness before extending
- [Testing] Two-layer integration test requires both Layer 1 (pre-commit hook) and Layer 2 (PreToolUse sentinel) to be installed

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.
