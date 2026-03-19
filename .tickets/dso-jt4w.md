---
id: dso-jt4w
status: in_progress
deps: []
links: []
created: 2026-03-19T18:05:25Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-79
---
# Fix CLAUDE_PLUGIN_ROOT path resolution: remove settings.json override, harden shim fallback

## Context
DSO plugin scripts assume CLAUDE_PLUGIN_ROOT points to the plugin directory, but .claude/settings.json overrides Claude Code's auto-set value with the repo root, breaking path resolution for read-config.sh and other plugin resources. There is no clear boundary between plugin context (cached plugin, runtime) and project context (source, development/testing).

## Success Criteria
- CLAUDE_PLUGIN_ROOT is no longer overridden in .claude/settings.json
- Claude Code's auto-set CLAUDE_PLUGIN_ROOT flows through to plugin scripts unmodified
- When CLAUDE_PLUGIN_ROOT is not set (known Claude Code bugs), the shim falls back to dso.plugin_root from config and exports it, but only when it was not already set
- The BASH_SOURCE workaround in tk line 5146 is reverted
- tests/run-all.sh continues using REPO_ROOT/plugins/dso (project context, unchanged)
- tk sync successfully resolves read-config.sh via CLAUDE_PLUGIN_ROOT

## Approach
Remove CLAUDE_PLUGIN_ROOT from .claude/settings.json so Claude Code's auto-set cache path flows through. Harden the shim fallback so it only exports CLAUDE_PLUGIN_ROOT when the variable was not already set (preventing false positive overrides). Revert the BASH_SOURCE workaround in tk.

## Notes

<!-- note-id: ejtb3h49 -->
<!-- timestamp: 2026-03-19T18:05:49Z -->
<!-- origin: agent -->
<!-- sync: synced -->
Epic created via /dso:brainstorm. Option B chosen: remove override + harden shim fallback.
