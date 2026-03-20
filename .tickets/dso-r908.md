---
id: dso-r908
status: closed
deps: [dso-g7d8]
links: []
created: 2026-03-20T18:10:09Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-zu4o
---
# Fix MIGRATION-TO-PLUGIN.md to remove settings.json CLAUDE_PLUGIN_ROOT env override recommendation

TDD GREEN phase for dso-zu4o (depends on dso-g7d8 RED test).

Update plugins/dso/docs/MIGRATION-TO-PLUGIN.md to remove the recommendation to set CLAUDE_PLUGIN_ROOT in .claude/settings.json as the primary installation approach.

CURRENT (incorrect) guidance at lines 70-82:
  'Set CLAUDE_PLUGIN_ROOT in your project's .claude/settings.json so all hooks and skills resolve paths correctly: {"env": {"CLAUDE_PLUGIN_ROOT": "/path/to/digital-service-orchestra"}, ...}'

CORRECT approach (canonical since dso-kknz):
  The .claude/scripts/dso shim resolves CLAUDE_PLUGIN_ROOT automatically from dso.plugin_root in .claude/dso-config.conf. Users should NOT manually set CLAUDE_PLUGIN_ROOT in settings.json.

Changes required:
1. Step 1 of migration (Install the Plugin): Replace 'Set CLAUDE_PLUGIN_ROOT in settings.json' with guidance to run dso-setup.sh which writes dso.plugin_root to .claude/dso-config.conf and installs the shim automatically.
2. Troubleshooting table: Remove rows about 'env block missing from settings.json' and 'CLAUDE_PLUGIN_ROOT: unbound variable' from settings.json, update with shim-based troubleshooting.
3. Verify section: Update step to confirm plugin is active (no longer requires CLAUDE_PLUGIN_ROOT set).
4. Remove the CLAUDE_PLUGIN_ROOT env block JSON example from Step 1.

TDD exemption: This task modifies only static Markdown documentation (criterion: 'static assets only — Markdown documentation, no executable assertion is possible'). The RED test task dso-g7d8 provides the failing assertion.

## ACCEPTANCE CRITERIA

- [ ] All tests in test-config-resolution-doc-accuracy.sh pass (GREEN)
  Verify: `bash tests/scripts/test-config-resolution-doc-accuracy.sh 2>&1 | grep -q "FAILED: 0"`
- [ ] MIGRATION-TO-PLUGIN.md does not recommend CLAUDE_PLUGIN_ROOT in settings.json
  Verify: `grep -c 'CLAUDE_PLUGIN_ROOT.*settings\.json\|settings\.json.*CLAUDE_PLUGIN_ROOT' plugins/dso/docs/MIGRATION-TO-PLUGIN.md | grep -q '^0$'`
- [ ] MIGRATION-TO-PLUGIN.md references dso-setup.sh as the install method
  Verify: `grep -q 'dso-setup.sh' plugins/dso/docs/MIGRATION-TO-PLUGIN.md`
- [ ] MIGRATION-TO-PLUGIN.md references dso-config.conf for plugin root config
  Verify: `grep -q 'dso-config.conf' plugins/dso/docs/MIGRATION-TO-PLUGIN.md`

## File Impact

### Files to modify
- `plugins/dso/docs/MIGRATION-TO-PLUGIN.md`

### Files to read (reference only)
- `plugins/dso/scripts/dso-setup.sh`
- `tests/scripts/test-config-resolution-doc-accuracy.sh` (RED test to make GREEN)

## Notes

<!-- note-id: izc1ikef -->
<!-- timestamp: 2026-03-20T18:37:52Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: dc1cz377 -->
<!-- timestamp: 2026-03-20T18:38:02Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 59g3j95d -->
<!-- timestamp: 2026-03-20T18:38:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (RED test verified failing) ✓

<!-- note-id: 61hzvien -->
<!-- timestamp: 2026-03-20T18:39:37Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: tcv3azwa -->
<!-- timestamp: 2026-03-20T18:39:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: GREEN — both tests pass (PASSED: 2 FAILED: 0) ✓

<!-- note-id: qs7282qk -->
<!-- timestamp: 2026-03-20T18:39:47Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
