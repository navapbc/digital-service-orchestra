---
id: dso-zs27
status: closed
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

## ACCEPTANCE CRITERIA

- [ ] Test from dso-2rgm passes (GREEN) after this fix
  Verify: `bash tests/scripts/test-config-resolution-doc-accuracy.sh`
- [ ] CONFIG-RESOLUTION.md no longer contains CLAUDE_PLUGIN_ROOT as a resolution step
  Verify: `grep -c 'CLAUDE_PLUGIN_ROOT.*dso-config' plugins/dso/docs/CONFIG-RESOLUTION.md | grep -q '^0$'`
- [ ] CONFIG-RESOLUTION.md documents WORKFLOW_CONFIG_FILE as step 1
  Verify: `grep -q 'WORKFLOW_CONFIG_FILE' plugins/dso/docs/CONFIG-RESOLUTION.md`
- [ ] CONFIG-RESOLUTION.md documents git rev-parse canonical path as step 2
  Verify: `grep -q 'git rev-parse' plugins/dso/docs/CONFIG-RESOLUTION.md`

## File Impact

### Files to modify
- `plugins/dso/docs/CONFIG-RESOLUTION.md`

### Files to read (reference only)
- `plugins/dso/scripts/read-config.sh`
- `tests/scripts/test-config-resolution-doc-accuracy.sh` (RED test to make GREEN)

## Notes

**2026-03-20T18:26:05Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T18:26:14Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T18:26:25Z**

CHECKPOINT 3/6: Tests written (RED test verified failing) ✓

**2026-03-20T18:26:52Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T18:27:28Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T18:27:40Z**

CHECKPOINT 6/6: Done ✓
