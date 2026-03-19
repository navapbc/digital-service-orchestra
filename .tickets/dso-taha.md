---
id: dso-taha
status: in_progress
deps: []
links: []
created: 2026-03-19T18:18:42Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-jt4w
jira_key: DIG-81
---
# Add failing test for shim CLAUDE_PLUGIN_ROOT preservation (RED)

Write a test (`test_shim_preserves_claude_plugin_root_when_preset`) that verifies
the `.claude/scripts/dso` shim does NOT overwrite `CLAUDE_PLUGIN_ROOT` when it is
already set by the caller (e.g., by Claude Code). The test should fail against the
current shim code (lines 32-36 unconditionally re-export).

TDD RED phase — this test must fail before dso-ilna implements the fix.

## ACCEPTANCE CRITERIA

- Test file exists for shim CLAUDE_PLUGIN_ROOT preservation
  Verify: `test -f tests/scripts/test-dso-shim-plugin-root.sh && echo PASS || echo FAIL`
- Test exercises the shim with CLAUDE_PLUGIN_ROOT pre-set and validates preservation
  Verify: `grep -q 'CLAUDE_PLUGIN_ROOT' tests/scripts/test-dso-shim-plugin-root.sh && echo PASS || echo FAIL`
- Test fails (RED) against the current shim implementation (lines 32-36 unconditionally re-export)

## File Impact

- `tests/scripts/test-dso-shim-plugin-root.sh`


## Notes

<!-- note-id: 00ne5md6 -->
<!-- timestamp: 2026-03-19T20:13:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: bh57xfwj -->
<!-- timestamp: 2026-03-19T20:14:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: jt9mpjnc -->
<!-- timestamp: 2026-03-19T20:20:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: c6xxzfu8 -->
<!-- timestamp: 2026-03-19T20:20:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: g7jelq13 -->
<!-- timestamp: 2026-03-19T20:20:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: z95thjom -->
<!-- timestamp: 2026-03-19T20:21:05Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
