---
id: dso-fxib
status: open
deps: [dso-x1jt, dso-dghs, dso-d8gi, dso-47gy]
links: []
created: 2026-03-18T17:58:29Z
type: story
priority: 3
assignee: Joe Oakhart
parent: dso-l2ct
---
# Update project docs to reflect dso:sprint optimization

## Description
**What:** Update `CLAUDE.md` to reflect the merged phase structure and removal of Task tracking calls from `/dso:sprint`. Audit all CLAUDE.md sections (Architecture, Critical Rules, Quick Reference, Common Fixes) for stale references to the old Phase 3/Phase 4 split or TaskCreate/TaskUpdate as sprint progress tracking.

**Why:** Documentation referencing a removed system misleads agents about current behavior. CLAUDE.md is loaded into every agent context — stale sprint phase references propagate through every sprint session.

**Scope:**
- IN: CLAUDE.md quick reference table phase numbering; any CLAUDE.md section referencing old Phase 3/Phase 4 or TaskCreate/TaskUpdate as sprint progress tracking
- OUT: Skill file changes (all done by dso-x1jt through dso-47gy); docs beyond CLAUDE.md unless they contain explicit phase references
- Depends on dso-x1jt, dso-dghs, dso-d8gi, dso-47gy (audit target is the final state)

Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for formatting, structure, and conventions.

## Done Definitions
- When this story is complete, CLAUDE.md quick reference table reflects the merged phase numbering from dso-d8gi
  ← Satisfies: "No documentation file references the old Phase 3/Phase 4 split"
- When this story is complete, all CLAUDE.md sections (Architecture, Critical Rules, Quick Reference, Common Fixes) have been audited for references to old sprint phase structure or TaskCreate/TaskUpdate as progress tracking, and any stale references are updated
  ← Satisfies: "Stale references in Architecture narrative or Critical Rules that agents consume for behavioral guidance are removed"
- When this story is complete, `bash tests/run-all.sh` passes with 0 failures

## Considerations
- [Maintainability] CLAUDE.md Architecture section contains sprint-related descriptions that may reference phase numbers — audit beyond the quick reference table.

## Notes

Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for documentation formatting, structure, and conventions.
