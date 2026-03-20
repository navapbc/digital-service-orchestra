---
id: dso-cn4j
status: in_progress
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

## Notes

<!-- note-id: id06tow5 -->
<!-- timestamp: 2026-03-20T15:25:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: yf1pwpbi -->
<!-- timestamp: 2026-03-20T15:25:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — test-config-callers-updated.sh and test-docs-config-refs.sh both currently pass; test_sprint_next_batch_uses_conf still checks for 'workflow-config.conf' (line 34) and the assert label needs updating; test_no_hardcoded_workflow_config_conf_in_scripts already present. Need to update test_sprint_next_batch_uses_conf to check .claude/dso-config.conf pattern and update assert label.

<!-- note-id: 6yn37cd4 -->
<!-- timestamp: 2026-03-20T15:25:51Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: test-config-callers-updated.sh updated ✓ — test_sprint_next_batch_uses_conf now checks '.claude/dso-config.conf' instead of 'workflow-config.conf'; also filters comment lines. All 6 tests still pass.

<!-- note-id: b5ldw8fz -->
<!-- timestamp: 2026-03-20T15:29:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Changes verified ✓ — test-config-callers-updated.sh: 10 passed, 0 failed; test_sprint_next_batch_uses_conf now checks .claude/dso-config.conf with comment-line filtering; test_no_hardcoded_workflow_config_conf_in_scripts present and passing.

<!-- note-id: 2u5bhvl4 -->
<!-- timestamp: 2026-03-20T15:29:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: test-docs-config-refs.sh verified ✓ — 4 passed, 0 failed; no changes needed per task spec.

<!-- note-id: 087dy1tc -->
<!-- timestamp: 2026-03-20T15:29:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — AC verified: test-config-callers-updated.sh exits 0 (10 passed, 0 failed); test_no_hardcoded_workflow_config_conf_in_scripts PASS; test-docs-config-refs.sh exits 0 (4 passed, 0 failed). No discovered work requiring new tickets.
