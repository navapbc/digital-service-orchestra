---
id: dso-bugk
status: closed
deps: [dso-uc2d, dso-q2ev]
links: []
created: 2026-03-20T00:09:59Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-kknz
---
# As a DSO contributor, all references use the new config path and filename

## Description

**What**: Update all documentation, test fixtures, examples, and CLAUDE.md to reference `.claude/dso-config.conf` instead of `workflow-config.conf`.
**Why**: Eliminates confusion by ensuring all artifacts consistently reference the new location. Final cleanup pass after runtime resolution and setup are already migrated.
**Scope**:
- IN: All docs in `plugins/dso/docs/`, CLAUDE.md, test fixtures (data-only references, not resolution logic), example files (e.g., `workflow-config.example.conf` → `dso-config.example.conf`), skill/command documentation
- OUT: Runtime config resolution scripts (Story dso-uc2d), setup script (Story dso-q2ev)

## Done Definitions

- When this story is complete, all references in plugins/dso/ docs, skills, commands, CLAUDE.md, test fixtures, and examples use the new path and filename exclusively
  ← Satisfies: "All references use the new path and filename exclusively"
- When this story is complete, `grep -r 'workflow-config.conf' plugins/ CLAUDE.md` returns zero matches (excluding git history)
  ← Satisfies: "grep returns zero matches"
- When this story is complete, `validate.sh --ci` passes end-to-end, confirming no regressions
  ← Satisfies: "validate.sh --ci passes end-to-end"

## Considerations

- [Maintainability] Rename touches 30+ files — grep-based verification provides a safety net but may miss semantic references (e.g., prose describing "place config at repo root" without naming the file). Audit prose descriptions, not just filenames.

