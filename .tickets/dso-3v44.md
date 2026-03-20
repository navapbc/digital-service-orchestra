---
id: dso-3v44
status: open
deps: []
links: []
created: 2026-03-20T03:33:14Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# RED: Write failing tests for runtime scripts hardcoded config path

## TDD Requirement (RED phase): Write failing tests first

Extend tests/scripts/test-config-callers-updated.sh with new test cases asserting that runtime scripts have been updated from workflow-config.conf to .claude/dso-config.conf path construction.

### New tests to add:

test_validate_sh_uses_dot_claude_config — validate.sh constructs CONFIG_FILE as $REPO_ROOT/.claude/dso-config.conf (not $REPO_ROOT/workflow-config.conf).

test_validate_phase_sh_uses_dot_claude_config — validate-phase.sh uses $REPO_ROOT/.claude/dso-config.conf.

test_sprint_next_batch_uses_dot_claude_config — sprint-next-batch.sh constructs config path as $REPO_ROOT/.claude/dso-config.conf.

test_no_hardcoded_workflow_config_conf_in_scripts — grep plugins/dso/scripts/*.sh for active (non-comment) hardcoded 'workflow-config.conf' path construction returns zero matches (excluding read-config.sh which handles format detection, and validate-config.sh which handles legacy validation).

### Constraints
- Do NOT change any runtime scripts in this task
- Tests check source code patterns via grep — they verify the implementation in task dso-2vwl
- Tests must fail (RED) before the implementation task runs

## ACCEPTANCE CRITERIA

- [ ] tests/scripts/test-config-callers-updated.sh contains test_validate_sh_uses_dot_claude_config
  Verify: grep -q 'test_validate_sh_uses_dot_claude_config' $(git rev-parse --show-toplevel)/tests/scripts/test-config-callers-updated.sh
- [ ] tests/scripts/test-config-callers-updated.sh contains test_no_hardcoded_workflow_config_conf_in_scripts
  Verify: grep -q 'test_no_hardcoded_workflow_config_conf_in_scripts' $(git rev-parse --show-toplevel)/tests/scripts/test-config-callers-updated.sh
- [ ] New tests FAIL before implementation (RED confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-config-callers-updated.sh 2>&1 | grep -qE 'FAIL'
- [ ] bash tests/run-all.sh shows no regressions from test addition alone
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5
