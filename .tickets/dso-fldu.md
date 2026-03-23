---
id: dso-fldu
status: open
deps: []
links: []
created: 2026-03-22T16:41:00Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Sprint displays blocker relationships for blocked epics


## Notes

<!-- note-id: 9w9x1xqx -->
<!-- timestamp: 2026-03-22T16:41:10Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Context
Developers using /dso:sprint see blocked epics listed with no indication of whats blocking them. To identify the blocker, they must manually run tk show on each blocked epic. This friction makes prioritization harder — you cant tell which epic to complete to unblock downstream work, or which unblocked epics are high-leverage because they hold other epics back. This affects every sprint session where epics have blocking dependencies, which is common in multi-epic sprints.

## Success Criteria
1. When sprint-list-epics.sh displays a blocked epic, the output includes the IDs of the blocking epic(s) so the user can immediately see what needs to complete first. The blocker data comes from the existing deps field already read by the script — no new data source is needed.
2. When an unblocked (or in-progress) epic is a dependency of one or more blocked epics, it is visually distinguished in the sprint display (bolded) so the user can identify high-leverage work at a glance.
3. /dso:sprint Phase 1 epic selection display consumes the enhanced output and renders both the blocker IDs and the bold markers without additional tk show calls. Validation: run /dso:sprint on a backlog with at least one blocked epic and confirm the blocked epics output line includes the blocking epic ID(s), and the blocking epics line renders with bold formatting.

## Dependencies
- dso-l2ct (soft coordination — if dso-l2ct restructures /dso:sprint Phase 1 before this lands, display logic targets the renamed phase; this epics changes are additive rendering, not phase restructuring)

## Approach
Enhance sprint-list-epics.sh to include blocker IDs in blocked-epic output lines and add a marker for unblocked epics that block others. Sprint skill display logic updated to render markers. All data already available in the scripts existing dep-resolution pass.
