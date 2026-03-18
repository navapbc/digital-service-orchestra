---
id: dso-8jf6
status: open
deps: []
links: []
created: 2026-03-18T00:39:14Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Assess and align acceptance criteria standards: preplanning stories vs implementation-plan tasks

issue-quality-check.sh has two modes: a strict modern check (requires ## Acceptance Criteria block + ## File Impact section) and a legacy fallback (looser check for tickets with criteria in prose under ## Notes). Preplanning-generated stories currently pass only the legacy check because they embed done definitions in prose under ## Notes rather than using the structured ## Acceptance Criteria block. Meanwhile, implementation-plan tasks are expected to use the structured format. We need to decide: should preplanning stories generate structured ## Acceptance Criteria blocks? Should the quality check treat stories differently from tasks? This needs an interactive conversation with the user to define the right standard before implementing. Resolution requires: (1) user conversation to define the standard, (2) update preplanning skill output format if needed, (3) update issue-quality-check.sh to apply the agreed standard.


## Notes

**2026-03-18T00:55:37Z**

Design decision: Acceptance Criteria blocks are implementation-level constructs — they belong on Tasks, not Stories. Stories should use prose done-definitions (the 'As a user...' narrative format). issue-quality-check.sh should enforce AC blocks only on type:task tickets, and apply a lighter quality check (prose done-definitions sufficient) for type:story tickets. Resolution: update issue-quality-check.sh to branch on ticket type field before applying the structured-block check.
