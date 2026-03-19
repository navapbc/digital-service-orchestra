---
id: dso-ilna
status: in_progress
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

## Notes

<!-- note-id: mlwj5by2 -->
<!-- timestamp: 2026-03-19T20:32:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 8wkq878j -->
<!-- timestamp: 2026-03-19T20:32:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: di3f8n3d -->
<!-- timestamp: 2026-03-19T20:32:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required — dso-taha wrote RED test) ✓

<!-- note-id: it7im6m0 -->
<!-- timestamp: 2026-03-19T20:33:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: c3u6s6a1 -->
<!-- timestamp: 2026-03-19T20:33:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: u0lq8fla -->
<!-- timestamp: 2026-03-19T20:34:02Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
