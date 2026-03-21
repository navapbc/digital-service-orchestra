---
id: dso-dsa8
status: closed
deps: []
links: []
created: 2026-03-18T17:20:58Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-55
parent: dso-9xnr
---
# Bug: validate-issues.sh has no unit tests — add test suite covering core checks


`scripts/validate-issues.sh` has no dedicated test suite. All 10+ check functions (check_empty_epics, check_ticket_count, check_orphaned_tasks, check_circular_dependencies, check_mislinked_dependencies, check_child_parent_deps, check_cross_epic_child_deps, check_duplicate_titles, check_missing_descriptions, check_in_progress_without_notes) run untested except via incidental integration coverage.

The absence of tests means behavior changes (like the recent childless-epic and ticket-count changes) cannot be verified in isolation and regressions may not be caught.

## ACCEPTANCE CRITERIA

- [ ] Test file `tests/scripts/test-validate-issues.sh` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-validate-issues.sh
- [ ] Tests cover check_empty_epics (verbose-only, no MINOR issues for childless epics)
  Verify: grep -q "test.*empty_epic\|test.*childless" $(git rev-parse --show-toplevel)/tests/scripts/test-validate-issues.sh
- [ ] Tests cover check_ticket_count (warn ≥300, error ≥600 thresholds)
  Verify: grep -q "test.*ticket_count\|test.*300\|test.*600" $(git rev-parse --show-toplevel)/tests/scripts/test-validate-issues.sh
- [ ] Tests cover check_orphaned_tasks
  Verify: grep -q "test.*orphan" $(git rev-parse --show-toplevel)/tests/scripts/test-validate-issues.sh
- [ ] At least 8 tests total, all passing
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-validate-issues.sh 2>&1 | grep -q "FAILED: 0"
- [ ] bash tests/run-all.sh passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | grep -q "Overall: PASS"

## Notes

<!-- note-id: smr0hi32 -->
<!-- timestamp: 2026-03-21T00:26:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: behavioral (missing test coverage), Score: 0 (BASIC). Fix: create tests/scripts/test-validate-issues.sh with 10+ tests covering check_empty_epics, check_ticket_count, check_orphaned_tasks, check_duplicate_titles, check_child_parent_deps, check_missing_descriptions, check_in_progress_without_notes. Use TICKETS_DIR env var with fixture files to avoid live data dependencies.

<!-- note-id: uqdy3siz -->
<!-- timestamp: 2026-03-21T00:53:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: created tests/scripts/test-validate-issues.sh with 13 tests covering check_empty_epics, check_ticket_count, check_orphaned_tasks, check_duplicate_titles, check_child_parent_deps, check_missing_descriptions, check_in_progress_without_notes, --quick mode, and closed ticket exclusion

<!-- note-id: m9jb6r4i -->
<!-- timestamp: 2026-03-21T00:54:21Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: added 13-test suite for validate-issues.sh (commit 0111e9f)
