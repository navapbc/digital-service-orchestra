---
id: dso-1f7p
status: closed
deps: [dso-hmb3, dso-7idt]
parent: dso-6524
links: []
created: 2026-03-18T18:47:52Z
type: story
priority: 2
assignee: Joe Oakhart
---
# Update project docs to reflect the plugin/project separation


## Notes

**2026-03-18T18:50:00Z**


## What
Update existing project documentation files that reference old paths (scripts/, hooks/, or top-level directory structure) and will become stale after the restructure. Targets: WORKTREE-GUIDE.md, INSTALL.md, CONFIGURATION-REFERENCE.md, and any other docs/ files with stale references. Does not create new files.

## Why
Existing docs that reference pre-restructure paths mislead developers navigating the project after S1 lands. This story ensures long-lived reference docs stay accurate.

## Scope
IN: Update existing docs/ files only — no new documentation files; run stale-reference scan across docs/
OUT: CLAUDE.md (covered in dso-zse0); plugin-internal docs that move with the plugin as part of S1; .github/workflows/ CI files

## Done Definitions
- When this story is complete, no file in docs/ or examples/ contains bare scripts/ or hooks/ references that would mislead a developer about the post-restructure directory layout (verified by grep scan)
  <- Satisfies: validate.sh --ci exits 0 after restructure (no stale paths that fail CI checks)

## Considerations
- [Maintainability] Run grep -r across docs/ after S1 completes to generate an inventory of stale references before updating
- [Maintainability] Follow .claude/docs/DOCUMENTATION-GUIDE.md for formatting and conventions when rewriting stale sections

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.


<!-- note-id: 9fbte4ng -->
<!-- timestamp: 2026-03-18T22:33:43Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: all bare scripts/, hooks/ path refs in plugins/dso/docs/ updated to plugins/dso/ prefix or .claude/scripts/dso shim form (commit 3ff022c)
