---
id: w21-lskq
status: open
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
