---
id: dso-d8gi
status: open
deps: [dso-x1jt, dso-dghs]
links: []
created: 2026-03-18T17:58:29Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-l2ct
jira_key: DIG-71
---
# As a DSO practitioner, batch preparation is a single phase with pre-flight then claim then sync then compose ordering

## Description
**What:** Merge Phase 3 (Batch Planning) and Phase 4 (Pre-Batch Checks) of `skills/sprint/SKILL.md` into a single phase. The merged phase steps must be in this order: (1) pre-flight checks (determines max_agents), (2) claim tasks, (3) sync from main, (4) batch composition using max_agents. After merging, renumber all phases and substeps sequentially with no gaps.

**Why:** The current Phase 3/Phase 4 split is artificial — both phases serve batch preparation. The pre-flight check must precede batch composition (it determines max_agents used by batch composition), but currently this ordering constraint is only enforced by the phase split, not by explicit step sequencing within a single phase.

**Scope:**
- IN: Merging Phase 3 and Phase 4 content, reordering steps as specified, renumbering all phases and substeps
- OUT: Prose pruning (dso-dghs — must complete before this story), table consolidation (dso-47gy)
- Depends on dso-x1jt and dso-dghs completing first (ordering constraint: renumber a leaner file)

## Done Definitions
- When this story is complete, the merged batch-prep phase has steps in this order: pre-flight checks → claim tasks → sync from main → batch composition
  ← Satisfies: "Phase 3 and Phase 4 merged with steps ordered: (1) pre-flight checks, (2) claim tasks, (3) sync from main, (4) batch composition"
- When this story is complete, all phase numbers and substep numbers are sequential with no gaps (Phase 1, 2, 3... not Phase 1, 2, 4...)
  ← Satisfies: "Phases renumbered sequentially from Phase 1; substeps renumbered contiguously within each phase"
- When this story is complete, `bash tests/run-all.sh` passes with 0 failures

## Considerations
- [Reliability] The ordering constraint is behavioral: pre-flight checks determine max_agents, and batch composition consumes max_agents. The merged phase must enforce this via step ordering, not just by proximity.
