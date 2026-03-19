---
id: dso-drn9
status: closed
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


## Notes

<!-- note-id: 5fm4lxcp -->
<!-- timestamp: 2026-03-19T20:38:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — No revert needed. The BASH_SOURCE workaround was never committed (unstaged local change lost during stash). Line 5146 already uses CLAUDE_PLUGIN_ROOT with BASH_SOURCE fallback, which is the correct pattern.

<!-- note-id: 15qmiv4k -->
<!-- timestamp: 2026-03-19T20:38:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: BASH_SOURCE workaround was never committed — line 5146 already uses CLAUDE_PLUGIN_ROOT. Verified correct.
