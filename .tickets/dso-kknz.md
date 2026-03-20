---
id: dso-kknz
status: open
deps: []
links: []
created: 2026-03-19T16:57:05Z
type: epic
priority: 0
assignee: Joe Oakhart
jira_key: DIG-46
---
# Move workflow config to .claude/dso-config.conf


## Notes

<!-- note-id: 2yb3bt75 -->
<!-- timestamp: 2026-03-20T00:02:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Context
Developers installing the DSO plugin into their projects end up with `workflow-config.conf` at the repo root, mixed in with application source files. This makes it unclear which files belong to the app vs. the tooling layer — new team members have to learn that this file is Claude-specific rather than project configuration. Moving it to `.claude/dso-config.conf` groups all Claude Code artifacts under `.claude/`, where developers already expect to find them.

## Success Criteria
- `read-config.sh` resolves config exclusively from `.claude/dso-config.conf` (relative to git root) — no fallback to the old path
- `dso-setup.sh` creates `.claude/dso-config.conf` in host projects (and does not create `workflow-config.conf`)
- The `.claude/scripts/dso` shim reads `dso.plugin_root` from `.claude/dso-config.conf`
- This repo's own config lives at `.claude/dso-config.conf` with no `workflow-config.conf` at root
- All references in `plugins/dso/` docs, skills, commands, CLAUDE.md, test fixtures, and examples use the new path and filename exclusively
- After migration, `grep -r 'workflow-config.conf' plugins/ CLAUDE.md` returns zero matches (excluding git history and changelogs)
- After migration, `validate.sh --ci` passes end-to-end, confirming no config resolution regressions across the full test and lint suite

## Dependencies
- This epic BLOCKS `dso-zu4o` (CLAUDE_PLUGIN_ROOT path resolution) and `dso-ghcp` (dso-setup.sh enhancements) — both modify `read-config.sh` and `dso-setup.sh`. This epic establishes the new config path first; downstream epics build on it. Enforced via `tk dep dso-zu4o dso-kknz` and `tk dep dso-ghcp dso-kknz`.
- `dso-0wi2` (project-level config flags) adds new keys to the config file but is path-independent — no dependency needed.

## Approach
Rename and re-path everywhere: change the canonical config path to `.claude/dso-config.conf` and update all references across scripts, docs, tests, and this repo's own config. Clean break — no fallback to the old path.
