---
id: w22-ubwu
status: open
deps: [w22-wwu2, w22-25ui, w22-2avn, w22-7r1n, w22-53cg, w22-agl5]
links: []
created: 2026-03-22T06:47:36Z
type: story
priority: 3
assignee: Joe Oakhart
parent: dso-5ooy
---
# As a DSO practitioner, overlay calibration baselines are established from retrospective analysis of merged commits

## Description

**What**: Run both overlays against the last 20 merged commits touching security/performance-sensitive paths and commit calibration baselines.
**Why**: Validates overlay trigger rates, finding volumes, and triage ratios before declaring the epic complete.
**Scope**:
- IN: Run classifier against 20 merged commits, run overlays on those that trigger, report trigger rate, findings per overlay, blue team dismissal rate, severity distribution, commit baselines
- OUT: Ongoing monitoring (future work)

## Done Definitions

- When this story is complete, a retrospective report has been generated covering overlay trigger rate, findings per overlay, blue team dismissal rate for security, and severity distribution for performance
- When this story is complete, calibration baselines are committed as the initial reference for post-deployment monitoring

## Considerations

- [Testing] May need synthetic test data if commit volume is low — ensure at least 20 commits through the classifier

