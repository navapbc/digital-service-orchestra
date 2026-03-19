---
id: dso-drn9
status: open
deps: [dso-ilna, dso-hpbh]
links: []
created: 2026-03-19T18:19:13Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-jt4w
jira_key: DIG-84
---
# Revert BASH_SOURCE workaround in tk sync path resolution

Revert the BASH_SOURCE workaround on tk line 5143 that was added to work around the
broken CLAUDE_PLUGIN_ROOT. Now that the settings.json override is removed (dso-hpbh)
and the shim correctly preserves the auto-set value (dso-ilna), the workaround is no
longer needed.

The original line used `CLAUDE_PLUGIN_ROOT` to find `read-config.sh`; the workaround
replaced it with a `BASH_SOURCE`-relative path. Restore the CLAUDE_PLUGIN_ROOT-based
resolution.

## Acceptance Criteria

- tk line ~5143 uses `CLAUDE_PLUGIN_ROOT` (not BASH_SOURCE) to resolve read-config.sh
- `tk sync` successfully resolves read-config.sh via the auto-set CLAUDE_PLUGIN_ROOT
- No other BASH_SOURCE workarounds remain in tk for this path

