---
id: dso-qlyk
status: open
deps: [dso-rmn7]
links: []
created: 2026-03-23T20:26:33Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-gy45
---
# Implement _phase_finalize() in cutover-tickets-migration.sh

Implement the _phase_finalize() stub in plugins/dso/scripts/cutover-tickets-migration.sh so the finalize phase performs all cleanup actions in a single atomic git commit.

## TDD Requirement
The RED tests from dso-rmn7 (tests/scripts/test-cutover-tickets-migration-finalize.sh) must fail before this task begins. Implementation is complete when all tests pass.

## Implementation Steps

1. Create pre-cleanup git tag 'pre-cleanup-migration' before any removal
2. Remove .tickets/ directory (REPO_ROOT/.tickets by default; use CUTOVER_TICKETS_DIR env var)
3. Remove plugins/dso/scripts/tk script
4. Remove tk-specific test fixtures: tests/scripts/test-tk-*.sh (glob), tests/plugin/test-bench-tk-ready.sh, plugins/dso/scripts/bench-tk-ready.sh, tests/hooks/test-tk-sync-force-local.sh
5. Check .gitattributes for stale .tickets/.index.json merge driver entry (not .tickets-tracker/); remove if found, preserving .tickets-tracker/.index.json entry
6. git add -A then single atomic commit: 'chore: remove .tickets/, tk script, and tk-specific test fixtures (cleanup commit)'
7. TICKET_COMPACT_DISABLED is already unset after _phase_migrate. Add a comment in _phase_finalize confirming compaction is re-enabled (env var no longer present).
8. Dry-run: when _DRY_RUN=true, skip git tag, rm, and git commit. Output is captured by _run_phase_dry wrapper.

## Constraints
- Idempotent: re-running when .tickets/ already absent must exit 0
- Do NOT remove .tickets-tracker/ (v3 system lives there)
- Commit must be independently revertible via git revert

## File
plugins/dso/scripts/cutover-tickets-migration.sh (_phase_finalize function at ~line 875)

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] _phase_finalize creates git tag 'pre-cleanup-migration'
  Verify: bash tests/scripts/test-cutover-tickets-migration-finalize.sh 2>&1 | grep -q 'test_finalize_creates_git_tag.*PASS'
- [ ] _phase_finalize removes .tickets/ directory
  Verify: bash tests/scripts/test-cutover-tickets-migration-finalize.sh 2>&1 | grep -q 'test_finalize_removes_tickets_dir.*PASS'
- [ ] _phase_finalize removes tk script
  Verify: bash tests/scripts/test-cutover-tickets-migration-finalize.sh 2>&1 | grep -q 'test_finalize_removes_tk_script.*PASS'
- [ ] _phase_finalize removes tk test fixtures
  Verify: bash tests/scripts/test-cutover-tickets-migration-finalize.sh 2>&1 | grep -q 'test_finalize_removes_tk_test_fixtures.*PASS'
- [ ] dry-run produces no file changes
  Verify: bash tests/scripts/test-cutover-tickets-migration-finalize.sh 2>&1 | grep -q 'test_finalize_dry_run_makes_no_changes.*PASS'
- [ ] idempotent: exits 0 when .tickets/ already absent
  Verify: bash tests/scripts/test-cutover-tickets-migration-finalize.sh 2>&1 | grep -q 'test_finalize_skips_if_tickets_dir_missing.*PASS'
- [ ] cutover script syntax check passes
  Verify: bash -c 'bash -n plugins/dso/scripts/cutover-tickets-migration.sh'

## Notes

<!-- note-id: xmbj6lkp -->
<!-- timestamp: 2026-03-23T20:27:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Description note added - see task title for full context. Implementation targets _phase_finalize() function. TDD dependency: dso-rmn7 RED tests must fail first.
