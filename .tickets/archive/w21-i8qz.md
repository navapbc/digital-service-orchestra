---
id: w21-i8qz
status: closed
deps: []
links: []
created: 2026-03-20T01:26:55Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-4xu6
---
# RED: Tests for value reviewer internal validation signals


## Notes

**2026-03-20T01:27:10Z**

## Description
Create or extend a test file with tests for the value reviewer prompt:
1. value.md does NOT contain 'usability testing', 'support ticket volume decrease', or 'A/B tests'
2. value.md DOES contain 'dogfooding', 'before/after', and 'operational metrics'
All tests FAIL (RED) because value.md still has external signals.

TDD: These ARE the RED tests.

## File Impact
- tests/scripts/ (new test file for value reviewer validation signals)
- plugins/dso/skills/brainstorm/docs/reviewers/value.md (read-only — target of assertions)

## ACCEPTANCE CRITERIA
- [ ] Test file exists at expected path
  Verify: test -f tests/scripts/test-value-reviewer-signals.sh
- [ ] Test checks that value.md does NOT contain external signals
  Verify: grep -q 'usability testing' tests/scripts/test-value-reviewer-signals.sh
- [ ] Test checks that value.md DOES contain internal signals
  Verify: grep -q 'dogfooding' tests/scripts/test-value-reviewer-signals.sh
- [ ] Running the tests returns non-zero exit (RED — tests fail before GREEN implementation)
  Verify: bash tests/scripts/test-value-reviewer-signals.sh 2>&1; test $? -ne 0

**2026-03-21T03:26:51Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T03:27:00Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T03:27:25Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T03:27:25Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T03:27:33Z**

CHECKPOINT 5/6: Validation passed ✓ (tests correctly fail in RED state: 4 failed, 2 passed)

**2026-03-21T03:27:47Z**

CHECKPOINT 6/6: Done ✓ — All 4 AC verified: test file exists, checks for external signals (usability testing), checks for internal signals (dogfooding), and returns non-zero exit in RED state
