---
id: dso-dsa8
status: open
deps: []
links: []
created: 2026-03-18T17:20:58Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-55
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
