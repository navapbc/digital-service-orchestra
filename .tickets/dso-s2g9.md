---
id: dso-s2g9
status: in_progress
deps: []
links: []
created: 2026-03-20T00:41:46Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-6576
---
# RED: Write failing tests for ci.workflow_name in validate-config.sh

Write failing tests (RED) for validate-config.sh that assert ci.workflow_name is recognized as a valid key.

TDD REQUIREMENT: Write two failing tests FIRST before touching validate-config.sh:
1. test_ci_workflow_name_valid_key — a config containing only 'ci.workflow_name=CI' must exit 0 (currently fails with 'unknown key')
2. test_merge_ci_workflow_name_still_valid — a config containing 'merge.ci_workflow_name=CI' must still exit 0 after the change (backward compat check)

IMPLEMENTATION STEPS:
1. Add both tests to tests/scripts/test-validate-config.sh following the existing fixture pattern (_snapshot_fail / CONF / assert_eq pattern)
2. Run: bash tests/scripts/test-validate-config.sh
3. Confirm test_ci_workflow_name_valid_key FAILS (ci.workflow_name not yet in KNOWN_KEYS) and test_merge_ci_workflow_name_still_valid PASSES

FILE: tests/scripts/test-validate-config.sh (edit — append tests before print_summary line)


## ACCEPTANCE CRITERIA

- [ ] `bash tests/scripts/test-validate-config.sh` runs without crashing
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config.sh 2>&1 | grep -qE 'PASS|FAIL'
- [ ] test_ci_workflow_name_valid_key test exists in test-validate-config.sh
  Verify: grep -q 'test_ci_workflow_name_valid_key' $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config.sh
- [ ] test_merge_ci_workflow_name_still_valid test exists in test-validate-config.sh
  Verify: grep -q 'test_merge_ci_workflow_name_still_valid' $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config.sh
- [ ] test_ci_workflow_name_valid_key is in RED state (fails before implementation)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config.sh 2>&1 | grep -q 'FAIL.*test_ci_workflow_name_valid_key'
- [ ] No pre-existing tests broken by the new test additions
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config.sh 2>&1 | grep 'FAIL' | grep -v 'test_ci_workflow_name_valid_key' | wc -l | awk '{exit ($1 > 0)}'

## Notes

**2026-03-20T00:59:18Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T00:59:39Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T00:59:55Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T01:00:11Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T01:00:48Z**

CHECKPOINT 6/6: Done ✓ — All 5 AC items verified. test_ci_workflow_name_valid_key is RED (fails with exit 1, ci.workflow_name not yet in KNOWN_KEYS). test_merge_ci_workflow_name_still_valid is GREEN (merge.ci_workflow_name already in KNOWN_KEYS). 14 pre-existing assertions pass, 0 pre-existing tests broken.
