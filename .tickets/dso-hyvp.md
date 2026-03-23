---
id: dso-hyvp
status: open
deps: [dso-qlyk, dso-rmn7]
links: []
created: 2026-03-23T20:30:06Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-gy45
---
# RED test + integration test for finalize dry-run on branch

Write and run a test that verifies the cutover script's finalize phase in --dry-run mode produces expected log output without modifying any files. This satisfies the done definition "Rollback tested on dry-run branch before production execution."

## TDD Requirement
Write a failing test FIRST in tests/scripts/test-cutover-finalize-dryrun.sh (fuzzy-match note: 'cutover' is NOT unique enough — add .test-index entry mapping cutover-tickets-migration.sh → test-cutover-finalize-dryrun.sh OR rename test to test-cutover-tickets-migration-dryrun.sh to ensure fuzzy match). The test must FAIL before dso-qlyk (_phase_finalize implementation) is complete.

Use filename: tests/scripts/test-cutover-tickets-migration-dryrun.sh (normalized: 'cutoverticketsmigrationdryrun' contains 'cutoverticketsmigration' — fuzzy match passes).

## Test Cases
1. test_dryrun_finalize_prefixes_output — run script with --dry-run --phase=finalize on a temp repo; assert all lines start with '[DRY RUN]'
2. test_dryrun_finalize_no_files_removed — after --dry-run --phase=finalize, .tickets/ still exists, tk script still exists, test-tk-*.sh files still exist
3. test_dryrun_finalize_no_commit_created — git log count is unchanged after --dry-run run
4. test_dryrun_finalize_no_git_tag — git tag --list shows no 'pre-cleanup-migration' tag after dry-run
5. test_dryrun_finalize_exits_zero — dry-run finalize exits 0

## Implementation Approach
Create a temp git repo. Populate it with stub .tickets/ dir, stub tk script, and stub test-tk-*.sh files. Run the cutover script with --dry-run --phase=finalize. Assert the above conditions.

IMPORTANT (Gap Analysis AC Amendment): The cutover script does NOT support a --phase=<name> skip flag — it always runs all phases in sequence. The test cases above that reference '--dry-run --phase=finalize' must be rewritten to use '--dry-run' only (all phases run in dry-run mode). Update test case names and assertions accordingly:
- test_dryrun_finalize_prefixes_output → use --dry-run (no --phase flag); assert output lines from the finalize phase contain '[DRY RUN]'
- All other test cases: run --dry-run (all phases), assert finalize-phase artifacts (tag, .tickets/ removal) did NOT happen

## Files
tests/scripts/test-cutover-tickets-migration-dryrun.sh (new file)

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file exists and is executable
  Verify: test -x tests/scripts/test-cutover-tickets-migration-dryrun.sh
- [ ] test_dryrun_finalize_no_files_removed test passes
  Verify: bash tests/scripts/test-cutover-tickets-migration-dryrun.sh 2>&1 | grep -q 'test_dryrun_finalize_no_files_removed.*PASS'
- [ ] test_dryrun_finalize_no_commit_created test passes
  Verify: bash tests/scripts/test-cutover-tickets-migration-dryrun.sh 2>&1 | grep -q 'test_dryrun_finalize_no_commit_created.*PASS'
- [ ] test_dryrun_finalize_exits_zero test passes
  Verify: bash tests/scripts/test-cutover-tickets-migration-dryrun.sh 2>&1 | grep -q 'test_dryrun_finalize_exits_zero.*PASS'
- [ ] test file is RED before dso-qlyk implementation (pre-implementation check)
  Verify: (documented in task — implementation agent verifies RED state before implementing dso-qlyk)

