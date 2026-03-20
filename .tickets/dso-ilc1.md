---
id: dso-ilc1
status: closed
deps: [dso-s2g9]
links: []
created: 2026-03-20T00:41:56Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-6576
---
# IMPL: Add ci.workflow_name to validate-config.sh KNOWN_KEYS

Add ci.workflow_name to the KNOWN_KEYS array in validate-config.sh, retaining merge.ci_workflow_name for backward compatibility.

TDD REQUIREMENT: This task depends on dso-s2g9 (RED tests). The test test_ci_workflow_name_valid_key must be FAILING before starting this task.

IMPLEMENTATION STEPS:
1. In plugins/dso/scripts/validate-config.sh, locate the KNOWN_KEYS array (line ~20-130)
2. In the CI section (after ci.integration_workflow), add: ci.workflow_name
3. Verify merge.ci_workflow_name is still present in the Merge section (do NOT remove it — backward compat)
4. Run: bash tests/scripts/test-validate-config.sh
5. Confirm test_ci_workflow_name_valid_key now PASSES (GREEN) and all other tests still pass

FILE: plugins/dso/scripts/validate-config.sh (edit — add ci.workflow_name to KNOWN_KEYS array)


## ACCEPTANCE CRITERIA

- [ ] ci.workflow_name is present in KNOWN_KEYS in validate-config.sh
  Verify: grep -q 'ci\.workflow_name' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate-config.sh
- [ ] merge.ci_workflow_name is still present in KNOWN_KEYS (backward compat)
  Verify: grep -q 'merge\.ci_workflow_name' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate-config.sh
- [ ] test_ci_workflow_name_valid_key now PASSES (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config.sh 2>&1 | grep -q 'PASS.*test_ci_workflow_name_valid_key\|test_ci_workflow_name_valid_key.*PASS'
- [ ] All existing validate-config.sh tests still pass
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config.sh 2>&1 | grep -c 'FAIL' | awk '{exit ($1 > 0)}'
- [ ] bash -n syntax check passes on validate-config.sh
  Verify: bash -n $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate-config.sh

## Notes

<!-- note-id: pibvuy7j -->
<!-- timestamp: 2026-03-20T01:18:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: ajaev2xs -->
<!-- timestamp: 2026-03-20T01:18:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: vsl7oa7v -->
<!-- timestamp: 2026-03-20T01:19:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (pre-existing RED tests) ✓

<!-- note-id: 1r7y4idt -->
<!-- timestamp: 2026-03-20T01:19:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: kj5r2col -->
<!-- timestamp: 2026-03-20T01:19:41Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: 5bxjj8ps -->
<!-- timestamp: 2026-03-20T01:20:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All 5 AC items verified PASS. AC4 grep-c false positive on 'FAILED: 0' summary line; actual test count is 15 PASSED, 0 FAILED.
