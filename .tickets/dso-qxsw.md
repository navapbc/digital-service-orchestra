---
id: dso-qxsw
status: open
deps: []
links: []
created: 2026-03-23T20:35:48Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# Fix remaining CI failures from v3 path migration


## Notes

<!-- note-id: qb96bnr0 -->
<!-- timestamp: 2026-03-23T21:01:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Investigation complete. Root causes identified and fixed:

1. test_phase_migrate_preserves_notes_with_timestamps (BLOCKING in CI batch 18):
   - Root cause: xargs -S 65536 is macOS-specific, fails on Linux/CI
   - Fix: replaced with portable while-read loop in test-cutover-tickets-migration.sh

2. test_*_names_tk_close_or_tk_status_as_prohibited (BLOCKING in CI batch 18):
   - Root cause: test checked for old 'tk close|tk status' commands after v3 migration renamed them to 'ticket transition|ticket create'
   - Fix: updated test-validate-work-readonly-enforcement.sh to check for new v3 command names

3. test_cutover_rollback_committed_uses_revert + test_cutover_exits_with_error (non-blocking):
   - These are RED marker tests in .test-index, expected to fail
   - Also improved _rollback_phase implementation to handle empty revert ranges

4. Previously-failing tests from earlier batches (skip-review, doc-migration, impl-plan-contracts, merge-squash-rebase, behavioral-equivalence, review-gate, compute-diff-hash):
   - All pass on current HEAD (fixed by batches 16-18)

ShellCheck: no violations on modified files.
Local test results: Script Tests 2679 PASSED / 2 FAILED (both RED markers)
