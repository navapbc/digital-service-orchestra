---
id: dso-g7d8
status: closed
deps: [dso-2rgm]
links: []
created: 2026-03-20T18:09:52Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-zu4o
---
# RED: Write test asserting MIGRATION-TO-PLUGIN.md does not recommend settings.json CLAUDE_PLUGIN_ROOT env override

TDD RED phase for dso-zu4o.

Write a new test function in tests/scripts/test-config-resolution-doc-accuracy.sh (same file as dso-2rgm) asserting MIGRATION-TO-PLUGIN.md does NOT recommend setting CLAUDE_PLUGIN_ROOT in settings.json as the primary installation approach.

The current MIGRATION-TO-PLUGIN.md (lines 70-82) instructs users:
  'Set CLAUDE_PLUGIN_ROOT in your project's .claude/settings.json so all hooks and skills resolve paths correctly'

This contradicts the current canonical approach: the dso shim reads dso.plugin_root from .claude/dso-config.conf. The settings.json env block approach is the OLD method that dso-zu4o aims to remove.

TDD requirement: Write test_migration_doc_no_settings_json_env_override that greps MIGRATION-TO-PLUGIN.md and asserts the pattern of recommending 'CLAUDE_PLUGIN_ROOT' in settings.json env block as a primary installation step does NOT appear. Must FAIL (RED) before the doc is corrected.

The test should:
1. Check that MIGRATION-TO-PLUGIN.md does not contain 'CLAUDE_PLUGIN_ROOT.*settings.json' or 'settings.json.*CLAUDE_PLUGIN_ROOT' as a primary recommendation (Step 1 of migration)
2. Use assert_eq to fail when the pattern is found

Depends on dso-2rgm (same test file).

## ACCEPTANCE CRITERIA

- [ ] Test function `test_migration_doc_no_settings_json_env_override` is defined in test-config-resolution-doc-accuracy.sh
  Verify: `grep -q "test_migration_doc_no_settings_json_env_override" tests/scripts/test-config-resolution-doc-accuracy.sh`
- [ ] Test FAILS (RED) when run against current MIGRATION-TO-PLUGIN.md
  Verify: `bash tests/scripts/test-config-resolution-doc-accuracy.sh 2>&1 | grep -q "FAILED: [1-9]"`
- [ ] Existing test_config_resolution_doc_no_claude_plugin_root_path still passes
  Verify: `bash tests/scripts/test-config-resolution-doc-accuracy.sh 2>&1 | grep -q "test_config_resolution_doc_no_claude_plugin_root_path.*PASS"`

## File Impact

### Files to modify
- `tests/scripts/test-config-resolution-doc-accuracy.sh`

### Files to read (reference only)
- `plugins/dso/docs/MIGRATION-TO-PLUGIN.md`

## Notes

<!-- note-id: dfa9lxwg -->
<!-- timestamp: 2026-03-20T18:33:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: q9caf65g -->
<!-- timestamp: 2026-03-20T18:33:15Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: qqnjl604 -->
<!-- timestamp: 2026-03-20T18:33:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: khjsz3hl -->
<!-- timestamp: 2026-03-20T18:33:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: y6w8tf8z -->
<!-- timestamp: 2026-03-20T18:34:05Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: New test FAILS RED (FAILED: 1), existing test still PASSES ✓

<!-- note-id: x9xna3y9 -->
<!-- timestamp: 2026-03-20T18:34:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
