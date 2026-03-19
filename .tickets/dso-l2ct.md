---
id: dso-l2ct
status: open
deps: [dso-ag1b, dso-iwb4]
links: []
created: 2026-03-18T17:43:47Z
type: epic
priority: 2
assignee: Joe Oakhart
jira_key: DIG-59
---
# Optimize /dso:sprint skill — prune bloat, merge phases, remove Task tracking


## Notes

**2026-03-18T17:43:58Z**


## Context
DSO practitioners who run epics via `/dso:sprint` face increasing context-window pressure as the skill file has grown to 1,356 lines. Each session loads the full skill into context; explanatory prose blocks ("Why this step exists"), motivation framing, and redundant reference tables inflate the load without contributing to agent behavior. Because the primary bloat is prose-heavy explanatory text, line and word count reduction are reliable proxies for token footprint reduction. The goal is to reduce context load while preserving every behavioral instruction.

## Scope
Prune `skills/sprint/SKILL.md` only. Remove: explanatory prose blocks, duplicate Quick Reference and Error Recovery tables, TaskCreate/TaskUpdate progress-checklist blocks. Do not alter: sub-agent dispatch order, model selection logic, validation gate conditions, dependency-resolution semantics.

## Success Criteria
- skills/sprint/SKILL.md is at least 25% smaller by line count than the pre-epic baseline (1,356 lines); word count also decreases by at least 20%
- Phase 3 (Batch Planning) and Phase 4 (Pre-Batch Checks) merged into a single phase with steps ordered: (1) pre-flight checks (determines max_agents), (2) claim tasks, (3) sync from main, (4) batch composition using max_agents. Phases renumbered sequentially from Phase 1; substeps renumbered contiguously within each phase
- Sub-agent model selection logic expressed as a markdown decision table with columns for parent_story_complex, task_model, task_class, and action — same logical decisions as current prose
- All TaskCreate/TaskUpdate progress-checklist blocks removed from Phase 1 (pre-loop) and Phase 3 (per-batch); functional calls outside those blocks preserved
- Quick Reference and Error Recovery tables merged into a single Reference & Recovery section: (1) Phase Overview subsection, (2) Error Situations subsection — no phase descriptions duplicated
- bash tests/run-all.sh passes with 0 failures
- Sub-agent dispatch behavior unchanged: same batch composition, model assignments, and commit sequence for a given epic

## Dependencies
- dso-ag1b (Display Task titles) and dso-iwb4 (Don't merge to main between batches) modify Phase 5-6 logic. Start this epic only after both are closed.

## Approach
Surgical pruning of human-facing explanations and redundant prose, combined with merging Phase 3 and Phase 4 into a single batch-prep phase and flattening model-selection logic into a decision table. Changes are deletions and reformatting only — no new behavior introduced.

