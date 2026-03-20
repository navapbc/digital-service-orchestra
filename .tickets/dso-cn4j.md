---
id: dso-cn4j
status: open
deps: [dso-opue, dso-6trc, dso-tuz0, dso-2vwl]
links: []
created: 2026-03-20T03:34:03Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# Update test-config-callers-updated.sh and test-docs-config-refs.sh for new path

## Documentation and Test Fixture Maintenance

Update existing test files that check for workflow-config.conf references to instead enforce .claude/dso-config.conf references.

### Changes to tests/scripts/test-config-callers-updated.sh

1. test_sprint_next_batch_uses_conf: Update to check for .claude/dso-config.conf (not workflow-config.conf):
   Change grep pattern from 'workflow-config.conf' to '.claude/dso-config.conf'
   Change assert label to reflect new path.

2. test_no_hardcoded_yaml_in_callers: This test already checks for .yaml; no change needed.

3. Add new test: test_no_hardcoded_workflow_config_conf_in_scripts
   Verify no active (non-comment) lines in scripts/*.sh construct workflow-config.conf paths
   Exclusions: read-config.sh (handles legacy format detection), validate-config.sh, submit-to-schemastore.sh, dso-setup.sh (separate story).

### Changes to tests/scripts/test-docs-config-refs.sh

This file currently checks for removal of workflow-config.yaml. No change needed for the .conf rename — that's covered by test-config-callers-updated.sh.

### Constraints
- Do NOT change test logic for tests that are already passing
- These are update/maintenance changes to existing tests — no new RED test phase needed
- The tests in this task depend on all implementation tasks completing first

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] tests/scripts/test-config-callers-updated.sh passes cleanly
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-config-callers-updated.sh 2>&1 | grep -E 'passed|0 failed'
- [ ] test_no_hardcoded_workflow_config_conf_in_scripts is present and passing
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-config-callers-updated.sh 2>&1 | grep -E 'test_no_hardcoded.*PASS'
