---
id: dso-boct
status: open
deps: []
links: []
created: 2026-03-21T23:20:00Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w21-ovpn
---
# As a DSO practitioner, the Light tier haiku reviewer applies a focused 6-item checklist to low-complexity changes


## Notes

<!-- note-id: t9c2dk6q -->
<!-- timestamp: 2026-03-21T23:20:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Description

**What**: Create the reviewer-delta-light.md checklist for the Light tier haiku reviewer with exactly 6 high-signal items.

**Why**: Light tier reviews low-complexity changes (classifier score 0-2). Haiku has limited context budget — the checklist must focus on what delivers value for small changes without codebase research.

## Acceptance Criteria

- When this story is complete, reviewer-delta-light.md contains exactly 6 checklist items:
  1. Silent failures: swallowed exceptions, empty catch blocks
  2. Tolerance/assertion weakening: changes that relax existing validation
  3. Test-code correspondence: production change without test change in same diff (binary check)
  4. Type system escape hatches: Any/any/interface{} without justifying comment
  5. Dead code introduced in the diff: unused imports, unreachable branches
  6. Non-descriptive names in the diff: single letters, generic words (data, temp, result, process, handle)
- When this story is complete, the checklist includes no codebase research instructions (no Grep/Read)
- When this story is complete, the checklist includes no similarity pipeline or ticket context references
- When this story is complete, the checklist includes escape hatch language: if no issues found, state so explicitly rather than manufacturing findings
- When this story is complete, build-review-agents.sh regenerates the light reviewer agent successfully

## Constraints
- No codebase research tools — haiku doesn't have the context budget
- Items must be evaluable from the diff alone

