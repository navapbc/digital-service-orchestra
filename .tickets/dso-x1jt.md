---
id: dso-x1jt
status: open
deps: []
links: []
created: 2026-03-18T17:58:29Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-l2ct
---
# As a DSO practitioner, Phase 1 and Phase 3 no longer contain TaskCreate/TaskUpdate checklist blocks

## Description
**What:** Remove all TaskCreate/TaskUpdate progress-checklist blocks from Phase 1 (pre-loop) and Phase 3 (per-batch initialization) of `skills/sprint/SKILL.md`. The pre-loop checklist in Phase 1 creates tasks like "Select and validate epic", "Run validation gate", etc. The per-batch checklist in Phase 3 creates tasks like "Batch N — Plan", "Batch N — Launch sub-agents", etc.

**Why:** These Task-based progress checklists do not reliably surface in the UI and add significant line count and token footprint to the skill without contributing to sub-agent behavior.

**Scope:**
- IN: TaskCreate/TaskUpdate calls in Phase 1 pre-loop block and Phase 3 per-batch initialization block
- OUT: Prose pruning (dso-dghs), phase merging (dso-d8gi), table consolidation (dso-47gy). Preserve any TaskCreate calls OUTSIDE those blocks (e.g., Phase 8 remediation task creation, Phase 7 post-loop validation checklist).

## Done Definitions
- When this story is complete, `skills/sprint/SKILL.md` contains no TaskCreate or TaskUpdate calls in the Phase 1 pre-loop checklist block or Phase 3 per-batch checklist initialization block
  ← Satisfies: "All TaskCreate/TaskUpdate progress-checklist blocks removed from Phase 1 (pre-loop) and Phase 3 (per-batch)"
- When this story is complete, `bash tests/run-all.sh` passes with 0 failures
  ← Satisfies: "bash tests/run-all.sh passes with 0 failures"

## Considerations
- [Reliability] Preserve functional TaskCreate calls that exist OUTSIDE the checklist blocks — specifically Phase 8 (remediation task creation) and Phase 7 (post-loop validation checklist items). Only remove the progress-indicator checklist blocks.
