---
id: dso-h7su
status: open
deps: [dso-1e6j, dso-bvna, dso-hsuo]
links: []
created: 2026-03-17T23:38:37Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-4g8u
---
# Update project docs to reflect automatic version bumping


## Notes

**2026-03-17T23:39:18Z**


**What:** Configure version bumping for this project and update documentation to reflect the new automated versioning system.

**Why:** Without setting `version.file_path` in this project's config, the automation won't run here. Future agents need to understand the config key and its behavior.

**Scope:**
- IN: Set `version.file_path=.claude-plugin/plugin.json` in this project's `workflow-config.conf`. Update `CLAUDE.md` architecture section to document the `version.file_path` config key, its default skip behavior when unset, and supported file formats. Review any other existing docs that reference versioning or the plugin version.
- OUT: Changes to scripts, skills, or the commit workflow (Stories dso-1e6j, dso-bvna, dso-hsuo).

**Done Definitions:**
- When complete, `workflow-config.conf` contains `version.file_path=.claude-plugin/plugin.json`
  ← Satisfies: "This project sets version.file_path=.claude-plugin/plugin.json in its own workflow-config.conf"
- When complete, `CLAUDE.md` architecture section documents the `version.file_path` config key, the skip behavior when unset, and the three supported file formats (.json, .toml, plaintext)
  ← Satisfies: general documentation criterion

**Considerations:**
- [Maintainability] `CLAUDE.md` is a protected file (CLAUDE.md rule 20) — user approval required before editing
- Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for documentation formatting, structure, and conventions.

