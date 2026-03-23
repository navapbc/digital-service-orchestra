---
id: dso-rmn7
status: closed
deps: []
links: []
created: 2026-03-23T20:26:09Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-gy45
---
# RED tests for _phase_finalize() in cutover-tickets-migration.sh

Write failing tests for the _phase_finalize() function in plugins/dso/scripts/cutover-tickets-migration.sh.

## TDD Requirement
Write tests FIRST in tests/scripts/test-cutover-tickets-migration-finalize.sh (fuzzy-matchable: 'cutover-tickets-migration' is a substring of 'test-cutover-tickets-migration-finalize'). Tests must FAIL before _phase_finalize() is implemented.

## Test Cases to Write
1. test_finalize_creates_git_tag — verify finalize phase creates git tag 'pre-cleanup-migration' (mock git, assert tag creation command called)
2. test_finalize_removes_tickets_dir — verify .tickets/ directory is removed during finalize
3. test_finalize_removes_tk_script — verify plugins/dso/scripts/tk is removed during finalize
4. test_finalize_removes_tk_test_fixtures — verify tests/scripts/test-tk-*.sh files are removed
5. test_finalize_removes_bench_tk — verify plugins/dso/scripts/bench-tk-ready.sh and tests/plugin/test-bench-tk-ready.sh are removed
6. test_finalize_removes_tk_sync_force_local_test — verify tests/hooks/test-tk-sync-force-local.sh is removed
7. test_finalize_commits_as_single_commit — verify finalize produces exactly one commit (not multiple)
8. test_finalize_dry_run_makes_no_changes — verify --dry-run flag produces expected output but modifies no files
9. test_finalize_unsets_compaction_disable_env — verify TICKET_COMPACT_DISABLED is not exported after finalize (compaction re-enabled)
10. test_finalize_skips_if_tickets_dir_missing — verify finalize exits 0 gracefully when .tickets/ already absent (idempotent)
11. test_finalize_handles_existing_tag — verify finalize is idempotent when 'pre-cleanup-migration' tag already exists (tag creation step must not fail or must skip gracefully)

## Implementation Approach
Use the same test structure as existing cutover tests. Create a temp git repo with a .tickets/ directory, tk script stub, and test fixture stubs. Invoke the cutover script's finalize phase and assert the expected state.

## File
tests/scripts/test-cutover-tickets-migration-finalize.sh (new file)

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file exists at expected path
  Verify: test -f tests/scripts/test-cutover-tickets-migration-finalize.sh
- [ ] Test file is executable
  Verify: test -x tests/scripts/test-cutover-tickets-migration-finalize.sh
- [ ] test_finalize_creates_git_tag function exists in test file
  Verify: grep -q 'test_finalize_creates_git_tag' tests/scripts/test-cutover-tickets-migration-finalize.sh
- [ ] Running the test file returns non-zero exit pre-implementation (RED state)
  Verify: bash tests/scripts/test-cutover-tickets-migration-finalize.sh; test $? -ne 0
- [ ] .test-index entry maps cutover-tickets-migration.sh to test-cutover-tickets-migration-finalize.sh
  Verify: grep -q 'cutover-tickets-migration.sh.*test-cutover-tickets-migration-finalize.sh' $(git rev-parse --show-toplevel)/.test-index


## Notes

**2026-03-23T21:13:06Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T21:13:45Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T21:15:11Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-23T21:15:34Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T21:16:05Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-23T21:16:20Z**

CHECKPOINT 6/6: Done ✓
