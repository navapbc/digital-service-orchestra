---
id: dso-jfy3
status: in_progress
deps: []
links: []
created: 2026-03-20T03:32:47Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# RED: Write failing tests for shim .claude/dso-config.conf resolution

## TDD Requirement (RED phase): Write failing tests first

Extend tests/scripts/test-dso-shim-plugin-root.sh (or test-shim-smoke.sh) with tests asserting the shim reads dso.plugin_root from .claude/dso-config.conf.

### Tests to add (in tests/scripts/test-dso-shim-plugin-root.sh):

test_shim_reads_plugin_root_from_dot_claude_dso_config — Given a temp git repo with .claude/dso-config.conf containing dso.plugin_root=<path>, the shim sets DSO_ROOT correctly.

test_shim_no_fallback_to_workflow_config_conf — Given a temp git repo with only workflow-config.conf at root (old location), the shim does NOT find DSO_ROOT from it (exits non-zero or returns empty DSO_ROOT).

### Constraints
- Do NOT change shim source in this task
- Locate the shim under test at .claude/scripts/dso in the repo
- Tests must fail (RED) before the implementation task runs

## ACCEPTANCE CRITERIA

- [ ] tests/scripts/test-dso-shim-plugin-root.sh contains test_shim_reads_plugin_root_from_dot_claude_dso_config
  Verify: grep -q 'test_shim_reads_plugin_root_from_dot_claude_dso_config' $(git rev-parse --show-toplevel)/tests/scripts/test-dso-shim-plugin-root.sh
- [ ] tests/scripts/test-dso-shim-plugin-root.sh contains test_shim_no_fallback_to_workflow_config_conf
  Verify: grep -q 'test_shim_no_fallback_to_workflow_config_conf' $(git rev-parse --show-toplevel)/tests/scripts/test-dso-shim-plugin-root.sh
- [ ] New tests FAIL before implementation (RED confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-shim-plugin-root.sh 2>&1 | grep -qE 'FAIL'
- [ ] bash tests/run-all.sh shows no regressions from test addition alone
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5

## Notes

**2026-03-20T04:20:14Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T04:20:35Z**

CHECKPOINT 2/6: Code patterns understood ✓ - shim at .claude/scripts/dso reads dso.plugin_root from workflow-config.conf at git root (step 2); tests use assert.sh helpers, mktemp git repos in TMPDIR_BASE, and call print_summary at end

**2026-03-20T04:21:09Z**

CHECKPOINT 3/6: Tests written ✓ - added test_shim_reads_plugin_root_from_dot_claude_dso_config and test_shim_no_fallback_to_workflow_config_conf to tests/scripts/test-dso-shim-plugin-root.sh

**2026-03-20T04:21:20Z**

CHECKPOINT 4/6: Implementation complete ✓ - No shim source changes (per task constraint). Tests written are the complete implementation for this RED phase task.

**2026-03-20T04:21:27Z**

CHECKPOINT 5/6: Validation passed ✓ - test file runs, 2 new tests FAIL (RED) as required: test_shim_reads_plugin_root_from_dot_claude_dso_config (FAIL: shim doesn't read .claude/dso-config.conf) and test_shim_no_fallback_to_workflow_config_conf (FAIL: shim still reads workflow-config.conf). 7 pre-existing tests still PASS.

**2026-03-20T04:25:17Z**

CHECKPOINT 6/6: Done ✓ - AC1: pass (test_shim_reads_plugin_root_from_dot_claude_dso_config present), AC2: pass (test_shim_no_fallback_to_workflow_config_conf present), AC3: pass (FAIL output confirmed RED), AC4: 7 pre-existing tests pass (no regressions), 2 new tests FAIL as required
