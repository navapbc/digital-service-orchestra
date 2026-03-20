---
id: dso-c2tl
status: in_progress
deps: []
links: []
created: 2026-03-20T03:32:24Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# RED: Write failing tests for config-paths.sh new path lookup

## TDD Requirement (RED phase): Write failing tests first

Extend tests/hooks/test-config-paths.sh with new test cases that assert config-paths.sh reads from .claude/dso-config.conf (not workflow-config.conf via CLAUDE_PLUGIN_ROOT lookup).

### New tests to add:

test_config_paths_reads_from_dot_claude_dso_config — When CLAUDE_PLUGIN_ROOT is NOT set but .claude/dso-config.conf exists at git root (simulated via temp git repo), config-paths.sh reads config values from .claude/dso-config.conf.

test_config_paths_no_claude_plugin_root_fallback — When CLAUDE_PLUGIN_ROOT is set to a dir containing workflow-config.conf (old behavior), config-paths.sh does NOT read from that file (new behavior: CLAUDE_PLUGIN_ROOT no longer used for config file lookup in config-paths.sh).

### Constraints
- Do NOT change config-paths.sh source in this task
- Tests must fail (RED) before the implementation task runs

## ACCEPTANCE CRITERIA

- [ ] tests/hooks/test-config-paths.sh contains test_config_paths_reads_from_dot_claude_dso_config
  Verify: grep -q 'test_config_paths_reads_from_dot_claude_dso_config' $(git rev-parse --show-toplevel)/tests/hooks/test-config-paths.sh
- [ ] tests/hooks/test-config-paths.sh contains test_config_paths_no_claude_plugin_root_fallback
  Verify: grep -q 'test_config_paths_no_claude_plugin_root_fallback' $(git rev-parse --show-toplevel)/tests/hooks/test-config-paths.sh
- [ ] New tests FAIL before implementation (RED confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-config-paths.sh 2>&1 | grep -qE 'FAIL'
- [ ] bash tests/run-all.sh shows no regressions from test addition alone
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5

## Notes

**2026-03-20T04:05:56Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T04:06:16Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T04:06:41Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T04:06:55Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED phase only — no source changes needed)

**2026-03-20T04:06:55Z**

CHECKPOINT 5/6: Validation passed ✓ — 14 existing tests pass, 5 new tests FAIL as expected (RED confirmed)
