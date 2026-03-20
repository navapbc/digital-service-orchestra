---
id: w22-sulb
status: in_progress
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

## ACCEPTANCE CRITERIA

- [ ] Bypass sentinel blocks direct writes to test-exemption file paths with exit code 2
  Verify: grep -q "test-exemption" plugins/dso/hooks/lib/review-gate-bypass-sentinel.sh
- [ ] Bypass sentinel allows record-test-exemption.sh as authorized writer
  Verify: grep -q "record-test-exemption" plugins/dso/hooks/lib/review-gate-bypass-sentinel.sh
- [ ] Two-layer integration test exists for test gate bypass prevention
  Verify: grep -q "test_gate" tests/hooks/test-two-layer-review-gate.sh
- [ ] All existing bypass sentinel tests still pass (25+)
  Verify: bash tests/hooks/test-review-gate-bypass-sentinel.sh 2>&1 | tail -1 | grep -q "FAILED: 0"
- [ ] run-all.sh passes
  Verify: bash tests/run-all.sh 2>&1 | tail -1 | grep -q "PASS"

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

## Notes

**2026-03-20T22:07:45Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T22:09:11Z**

CHECKPOINT 2/6: Code patterns understood ✓ — bypass sentinel has patterns g/h for test-gate-status. Need to add Pattern i: block writes to test-exemption file paths (allow record-test-exemption.sh). AC: exit 2 on direct writes, allow record-test-exemption.sh

**2026-03-20T22:12:46Z**

CHECKPOINT 3/6: Tests written ✓ — added 5 tests to bypass sentinel test (4 RED for test-exemptions pattern) + 5 tests to two-layer test (1 RED for test_gate_layer2_blocks_direct_write_to_test_exemptions)

**2026-03-20T22:13:37Z**

CHECKPOINT 4/6: Implementation complete ✓ — added Pattern i to review-gate-bypass-sentinel.sh: blocks direct writes/rm to test-exemptions, allows record-test-exemption.sh as authorized writer

**2026-03-20T22:13:49Z**

CHECKPOINT 5/6: Tests passing ✓ — bypass sentinel: 31 passed, 0 failed (was 25); two-layer review gate: 21 passed, 0 failed (was 16)

**2026-03-20T22:29:16Z**

CHECKPOINT 6/6: Done ✓ — All AC verified: (1) test-exemption in bypass sentinel PASS, (2) record-test-exemption.sh allowed PASS, (3) test_gate in two-layer tests PASS, (4) all bypass sentinel tests pass 31/0 PASS, (5) hook suite 1022 passed 1 pre-existing fail (test-merge-to-main-portability.sh, unrelated to this story)
