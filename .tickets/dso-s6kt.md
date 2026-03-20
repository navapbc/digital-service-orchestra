---
id: dso-s6kt
status: in_progress
deps: []
links: []
created: 2026-03-20T03:32:02Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# RED: Write failing tests for read-config.sh .claude/dso-config.conf resolution

## TDD Requirement (RED phase): Write failing tests first

Extend tests/scripts/test-read-config.sh with three new test cases that assert the new resolution behavior. These tests MUST fail (RED) before the implementation task runs.

### New tests to add:

test_resolves_from_dot_claude_dso_config_conf — Given a temp git repo with .claude/dso-config.conf (no workflow-config.conf), read-config.sh reads config from .claude/dso-config.conf.

test_no_fallback_to_workflow_config_conf — Given a temp git repo with only workflow-config.conf at root (no .claude/dso-config.conf), read-config.sh returns empty string exit 0 (no fallback to old path).

test_workflow_config_file_env_still_works — WORKFLOW_CONFIG_FILE env var still overrides all resolution (backward compat for test isolation).

### Constraints
- Do NOT change read-config.sh source in this task
- Use mktemp -d + git init + mkdir .claude pattern to simulate proper resolution environment
- Run bash tests/scripts/test-read-config.sh to confirm RED before committing

## ACCEPTANCE CRITERIA

- [ ] tests/scripts/test-read-config.sh contains test_resolves_from_dot_claude_dso_config_conf
  Verify: grep -q 'test_resolves_from_dot_claude_dso_config_conf' $(git rev-parse --show-toplevel)/tests/scripts/test-read-config.sh
- [ ] tests/scripts/test-read-config.sh contains test_no_fallback_to_workflow_config_conf
  Verify: grep -q 'test_no_fallback_to_workflow_config_conf' $(git rev-parse --show-toplevel)/tests/scripts/test-read-config.sh
- [ ] tests/scripts/test-read-config.sh contains test_workflow_config_file_env_still_works
  Verify: grep -q 'test_workflow_config_file_env_still_works' $(git rev-parse --show-toplevel)/tests/scripts/test-read-config.sh
- [ ] New tests FAIL before implementation (RED confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-read-config.sh 2>&1 | grep -qE 'FAIL'
- [ ] bash tests/run-all.sh shows no regressions from test file addition alone (only new tests fail)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5

## Notes

<!-- note-id: dq3a5v5j -->
<!-- timestamp: 2026-03-20T04:28:10Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 7zunmf0x -->
<!-- timestamp: 2026-03-20T04:28:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — read-config.sh resolves from WORKFLOW_CONFIG_FILE, CLAUDE_PLUGIN_ROOT/workflow-config.conf, or git-root/workflow-config.conf. New tests will assert .claude/dso-config.conf resolution which is not yet implemented.

<!-- note-id: 0jhpczyh -->
<!-- timestamp: 2026-03-20T04:28:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ — added test_resolves_from_dot_claude_dso_config_conf, test_no_fallback_to_workflow_config_conf, test_workflow_config_file_env_still_works to tests/scripts/test-read-config.sh

<!-- note-id: fbmj82fv -->
<!-- timestamp: 2026-03-20T04:29:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — No implementation change needed for RED phase; tests written only.
