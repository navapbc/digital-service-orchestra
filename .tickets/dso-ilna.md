---
id: dso-ilna
status: open
deps: [dso-taha]
links: []
created: 2026-03-19T18:19:54Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-jt4w
jira_key: DIG-86
---
# Harden shim: only export CLAUDE_PLUGIN_ROOT when not already set

In .claude/scripts/dso, track whether CLAUDE_PLUGIN_ROOT was the source of DSO_ROOT.
Change lines 32-36 so the re-export only fires when CLAUDE_PLUGIN_ROOT was NOT already
set (when DSO_ROOT came from the config fallback). When Claude Code sets CLAUDE_PLUGIN_ROOT
correctly, the shim must not touch it.

TDD: GREEN -- test_shim_preserves_claude_plugin_root_when_preset now passes.
