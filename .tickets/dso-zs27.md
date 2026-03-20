---
id: dso-zs27
status: open
deps: [dso-2rgm]
links: []
created: 2026-03-20T18:09:36Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-zu4o
---
# Fix CONFIG-RESOLUTION.md to accurately document read-config.sh resolution order

TDD GREEN phase for dso-zu4o (depends on dso-2rgm RED test).

Update plugins/dso/docs/CONFIG-RESOLUTION.md to match the actual resolution logic in plugins/dso/scripts/read-config.sh.

The current doc (line 7) incorrectly documents:
  '1. dso-config.conf at ${CLAUDE_PLUGIN_ROOT}/.claude/dso-config.conf (plugin-level override)'

The actual read-config.sh resolution order (from its source code comment):
  1. WORKFLOW_CONFIG_FILE env var (exact file path — highest priority, for test isolation)
  2. git rev-parse --show-toplevel/.claude/dso-config.conf (canonical path)
  3. Missing file → graceful degradation (empty output, exit 0)

Update the Resolution Order section to reflect these three steps. Remove the CLAUDE_PLUGIN_ROOT-based step entirely (it was removed from read-config.sh because CLAUDE_PLUGIN_ROOT points to the plugin dir, not the host project).

Also update the legacy fallback note — the 'workflow-config.yaml' legacy fallback section may still be present; verify it is either removed or accurately described.

TDD exemption: This task modifies only static Markdown documentation (criterion: 'static assets only — Markdown documentation, no executable assertion is possible'). The RED test task dso-2rgm provides the failing assertion.

Acceptance criteria:
- bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- Test from dso-2rgm passes after this fix
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-config-resolution-doc-accuracy.sh
- CONFIG-RESOLUTION.md no longer contains 'CLAUDE_PLUGIN_ROOT.*dso-config.conf' as a resolution step
  Verify: ! grep -qE 'CLAUDE_PLUGIN_ROOT.*dso-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/docs/CONFIG-RESOLUTION.md || grep -B2 'CLAUDE_PLUGIN_ROOT.*dso-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/docs/CONFIG-RESOLUTION.md | grep -qv '^[0-9]'

