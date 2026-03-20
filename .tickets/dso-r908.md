---
id: dso-r908
status: open
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

Acceptance criteria:
- bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- Test from dso-g7d8 passes after this fix
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-config-resolution-doc-accuracy.sh
- MIGRATION-TO-PLUGIN.md does not contain 'CLAUDE_PLUGIN_ROOT.*settings.json' as primary Step 1 guidance
  Verify: ! grep -n 'Set.*CLAUDE_PLUGIN_ROOT.*settings.json\|settings.json.*CLAUDE_PLUGIN_ROOT' $(git rev-parse --show-toplevel)/plugins/dso/docs/MIGRATION-TO-PLUGIN.md | grep -q 'Step 1'

