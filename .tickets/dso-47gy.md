---
id: dso-47gy
status: open
deps: [dso-d8gi]
links: []
created: 2026-03-18T17:58:29Z
type: story
priority: 3
assignee: Joe Oakhart
parent: dso-l2ct
---
# As a DSO practitioner, model selection is a decision table and reference/recovery content is in a single section

## Description
**What:** Convert the prose model-selection logic in `skills/sprint/SKILL.md` to a markdown decision table with columns: `parent_story_complex`, `task_model`, `task_class`, `action`. Merge the Quick Reference and Error Recovery tables into a single "Reference & Recovery" section with two subsections: (1) Phase Overview, (2) Error Situations.

**Why:** Prose model-selection logic is verbose and hard to scan. A decision table encodes the same logic in fewer lines. The Quick Reference and Error Recovery tables duplicate phase descriptions — merging them eliminates redundancy.

**Scope:**
- IN: Model selection prose → decision table; Quick Reference + Error Recovery → single "Reference & Recovery" section
- OUT: Phase renumbering (dso-d8gi — must complete first so Phase Overview uses final phase numbers)
- Depends on dso-d8gi (phase numbers must be final before writing Phase Overview table)

## Done Definitions
- When this story is complete, model selection is expressed as a markdown decision table with columns `parent_story_complex`, `task_model`, `task_class`, and `action`, encoding identical decision logic to the current prose
  ← Satisfies: "Sub-agent model selection logic expressed as a markdown decision table"
- When this story is complete, Quick Reference and Error Recovery are merged into a single "Reference & Recovery" section with Phase Overview and Error Situations subsections — no phase descriptions duplicated between the merged section and phase bodies
  ← Satisfies: "Quick Reference and Error Recovery tables merged into a single Reference & Recovery section"
- When this story is complete, `bash tests/run-all.sh` passes with 0 failures

## Considerations
- [Maintainability] Decision table must preserve all current branches including the COMPLEX story upgrade path (parent_story_complex=true, task_model=sonnet → upgrade to opus) and the skill-guided exception (task_class=skill-guided → no upgrade).
- [Maintainability] Verify that none of the model-selection decision branches reference Task-based progress state removed by dso-x1jt — encode only branches that remain valid after Task tracking removal.
