---
id: dso-jqin
status: in_progress
deps: []
links: []
created: 2026-03-18T23:14:27Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-guxa
---
# Remove Step 1.75 (Plugin Tests) from COMMIT-WORKFLOW.md and flip test assertion

Remove Step 1.75 and its Test Failure Delegation section from COMMIT-WORKFLOW.md, then flip the test assertion in test-check-plugin-test-needed.sh to verify the removal.

TDD Requirement: Write failing test FIRST.
In tests/scripts/test-check-plugin-test-needed.sh, update test_commit_workflow_has_plugin_test_step to assert that 'make test-plugin' is NOT present in COMMIT-WORKFLOW.md (flip the assertion from workflow_has_step=1 to assert_eq ... '0' "$workflow_has_step"). Run test to confirm RED (content still present). Then:

1. In plugins/dso/docs/workflows/COMMIT-WORKFLOW.md, remove:
   - The entire '## Step 1.75: Plugin Tests' section (lines ~228-242)
   - The entire '### Test Failure Delegation (Step 1.75)' section (lines ~244-277)
2. In tests/scripts/test-check-plugin-test-needed.sh, update test_commit_workflow_has_plugin_test_step:
   - Change: workflow_has_step=0; grep -q 'make test-plugin' ... && workflow_has_step=1
   - To assert that the step is ABSENT: assert_eq '...' '0' "$workflow_has_step"
   - Update comment to read '(c) COMMIT-WORKFLOW.md does NOT have Step 1.75 (intentionally removed)'

After changes, run bash tests/run-all.sh to confirm GREEN.

Files: plugins/dso/docs/workflows/COMMIT-WORKFLOW.md, tests/scripts/test-check-plugin-test-needed.sh

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] COMMIT-WORKFLOW.md does not contain 'Step 1.75'
  Verify: ! grep -q 'Step 1.75' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md
- [ ] COMMIT-WORKFLOW.md does not contain 'make test-plugin'
  Verify: ! grep -q 'make test-plugin' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md
- [ ] test-check-plugin-test-needed.sh asserts Step 1.75 is ABSENT (not present)
  Verify: grep -A3 'test_commit_workflow_has_plugin_test_step' $(git rev-parse --show-toplevel)/tests/scripts/test-check-plugin-test-needed.sh | grep -q '"0"'

## File Impact
- `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md` - remove Step 1.75 and Test Failure Delegation sections
- `tests/scripts/test-check-plugin-test-needed.sh` - flip assertion to verify Step 1.75 is absent from workflow

## Notes

<!-- note-id: sv0ayv6t -->
<!-- timestamp: 2026-03-19T00:06:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 26wmrnwt -->
<!-- timestamp: 2026-03-19T00:06:17Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 56rlwiga -->
<!-- timestamp: 2026-03-19T00:06:34Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: jshhmo24 -->
<!-- timestamp: 2026-03-19T00:06:57Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: qr7fzfnp -->
<!-- timestamp: 2026-03-19T00:10:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: f3k1lu7u -->
<!-- timestamp: 2026-03-19T00:10:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
