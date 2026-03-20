---
id: dso-o24g
status: in_progress
deps: []
links: []
created: 2026-03-20T00:42:09Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-6576
---
# RED: Write failing tests for ci.workflow_name fallback in merge-to-main.sh

Write failing tests (RED) for merge-to-main.sh that assert it reads ci.workflow_name (as CI_WORKFLOW_NAME via batch eval), falls back to merge.ci_workflow_name with deprecation warning, and produces empty string when both are absent.

TDD REQUIREMENT: Write three failing tests FIRST before touching merge-to-main.sh:
1. test_merge_to_main_reads_ci_workflow_name — script references CI_WORKFLOW_NAME (uppercase of ci.workflow_name) in the config resolution section
2. test_merge_to_main_fallback_to_merge_ci_workflow_name — when CI_WORKFLOW_NAME is empty, script falls back to MERGE_CI_WORKFLOW_NAME
3. test_merge_to_main_deprecation_warning — when fallback to merge.ci_workflow_name is triggered, a deprecation warning is emitted to stderr

Follow the pattern in tests/scripts/test-merge-to-main-config-driven.sh (grep-based assertions on the script source).

IMPLEMENTATION STEPS:
1. Create a new test file: tests/scripts/test-merge-to-main-ci-workflow-name.sh
2. Add the three tests using grep assertions on the merge-to-main.sh source
3. Run: bash tests/scripts/test-merge-to-main-ci-workflow-name.sh
4. Confirm all three tests FAIL (RED state — fallback logic not yet implemented)

FILE: tests/scripts/test-merge-to-main-ci-workflow-name.sh (create)


## ACCEPTANCE CRITERIA

- [ ] tests/scripts/test-merge-to-main-ci-workflow-name.sh exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-merge-to-main-ci-workflow-name.sh
- [ ] test_merge_to_main_reads_ci_workflow_name test exists in the new test file
  Verify: grep -q 'test_merge_to_main_reads_ci_workflow_name' $(git rev-parse --show-toplevel)/tests/scripts/test-merge-to-main-ci-workflow-name.sh
- [ ] test_merge_to_main_fallback_to_merge_ci_workflow_name test exists
  Verify: grep -q 'test_merge_to_main_fallback_to_merge_ci_workflow_name' $(git rev-parse --show-toplevel)/tests/scripts/test-merge-to-main-ci-workflow-name.sh
- [ ] test_merge_to_main_deprecation_warning test exists
  Verify: grep -q 'test_merge_to_main_deprecation_warning' $(git rev-parse --show-toplevel)/tests/scripts/test-merge-to-main-ci-workflow-name.sh
- [ ] All three tests currently FAIL (RED state before implementation)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-merge-to-main-ci-workflow-name.sh 2>&1 | grep -c 'FAIL' | awk '{exit ($1 < 3)}'
- [ ] test_merge_to_main_deprecation_warning asserts warning is sent to stderr (>&2 in source)
  Verify: grep -q 'DEPRECATION.*>&2\|>&2.*DEPRECATION' $(git rev-parse --show-toplevel)/plugins/dso/scripts/merge-to-main.sh || grep -q 'echo.*>&2' $(git rev-parse --show-toplevel)/plugins/dso/scripts/merge-to-main.sh

## Notes

**2026-03-20T00:59:00Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T00:59:33Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T01:00:53Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T01:00:53Z**

CHECKPOINT 4/6: Implementation complete ✓ — all 3 tests FAIL as expected (RED state)

**2026-03-20T01:01:12Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T01:01:43Z**

CHECKPOINT 6/6: Done ✓ — all 6 ACs pass, 3 tests correctly FAIL in RED state
