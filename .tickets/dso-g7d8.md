---
id: dso-g7d8
status: open
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

