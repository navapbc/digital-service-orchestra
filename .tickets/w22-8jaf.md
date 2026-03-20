---
id: w22-8jaf
status: closed
deps: [w22-uqfn]
links: []
created: 2026-03-20T14:53:27Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-ppwp
---
# As a developer, I can exempt a provably slow test from blocking commits

## Description

**What**: Slow test exemption mechanism — a protected script that proves a test is inherently slow and records an exemption the gate respects.
**Why**: Without this, a single test that inherently takes >60s would permanently block all commits touching its associated source file, creating an unresolvable deadlock.
**Scope**:
- IN: record-test-exemption.sh (accepts test node ID, runs in isolation with 60s timeout, writes exemption on timeout), gate modification to respect exemptions (exempted tests treated as passing for hash verification), exemption file format (node ID, threshold, timestamp)
- OUT: Automatic exemption detection (agent must manually invoke the script), exemption expiry (timestamp is for audit purposes only in this epic)

## Done Definitions

- When this story is complete, running record-test-exemption.sh with a test that exceeds 60s writes an exemption entry with node ID, threshold, and timestamp
  ← Satisfies: "record-test-exemption.sh accepts a single test node ID, runs it in isolation with a 60-second timeout, and writes an exemption only when the test exceeds the timeout"
- When this story is complete, running record-test-exemption.sh with a test that completes within 60s does NOT write an exemption and exits with an error
  ← Satisfies: "writes an exemption only when the test exceeds the timeout"
- When this story is complete, a commit touching a source file whose only associated test is exempted succeeds without running that test
  ← Satisfies: "the gate treats exempted tests as passing for hash verification"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Reliability] Exemption file must be consistently parsed by both the recording script and the pre-commit hook — single parsing path preferred

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

## Notes

**2026-03-20T21:58:18Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
