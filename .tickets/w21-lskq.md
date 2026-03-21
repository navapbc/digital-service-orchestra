---
id: w21-lskq
status: in_progress
deps: [w21-i8qz]
links: []
created: 2026-03-20T01:26:57Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-4xu6
---
# GREEN: Edit value.md validation_signal to use internal signals only


## Notes

**2026-03-20T01:27:13Z**

## Description
Edit plugins/dso/skills/brainstorm/docs/reviewers/value.md:
1. validation_signal dimension: remove external signals (usability testing, support ticket volume, A/B tests, analytics events/dashboards), replace with internal signals (before/after workflow comparisons, operational metrics, dogfooding observations, staged rollout with rollback criteria)
2. Instructions section: remove 'analytics events > A/B tests > formal usability studies' preference chain, remove external-facing examples (adoption signals, upload retry rates), replace with internal examples (workflow cycle time reduction, error rate decrease)
3. Preserve: 'shipping is not the same as solving the problem'

TDD: Task w21-i8qz RED tests turn GREEN after this edit.

## File Impact
- plugins/dso/skills/brainstorm/docs/reviewers/value.md (primary edit target)

## ACCEPTANCE CRITERIA
- [ ] value.md does NOT contain 'usability testing'
  Verify: { grep -q 'usability testing' plugins/dso/skills/brainstorm/docs/reviewers/value.md; test $? -ne 0; }
- [ ] value.md does NOT contain 'support ticket volume decrease'
  Verify: { grep -q 'support ticket volume decrease' plugins/dso/skills/brainstorm/docs/reviewers/value.md; test $? -ne 0; }
- [ ] value.md does NOT contain 'A/B tests'
  Verify: { grep -q 'A/B tests' plugins/dso/skills/brainstorm/docs/reviewers/value.md; test $? -ne 0; }
- [ ] value.md DOES contain 'dogfooding'
  Verify: grep -q 'dogfooding' plugins/dso/skills/brainstorm/docs/reviewers/value.md
- [ ] value.md DOES contain 'before/after'
  Verify: grep -q 'before/after' plugins/dso/skills/brainstorm/docs/reviewers/value.md
- [ ] value.md DOES contain 'operational metrics'
  Verify: grep -q 'operational metrics' plugins/dso/skills/brainstorm/docs/reviewers/value.md
- [ ] RED tests from w21-i8qz now pass (GREEN)
  Verify: bash tests/scripts/test-value-reviewer-signals.sh
- [ ] Preserves 'shipping is not the same as solving the problem' principle
  Verify: grep -q 'shipping is not the same as solving' plugins/dso/skills/brainstorm/docs/reviewers/value.md

**2026-03-21T03:37:49Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T03:37:55Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T03:37:56Z**

CHECKPOINT 3/6: Tests written (none required — RED tests exist) ✓

**2026-03-21T03:38:27Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T03:38:33Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T03:38:44Z**

CHECKPOINT 6/6: Done ✓
