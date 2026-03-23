---
id: dso-bdk5
status: closed
deps: []
links: []
created: 2026-03-23T17:34:42Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-k4sw
---
# RED tests for CLI-native ticket health guards


## Notes

**2026-03-23T17:35:13Z**

## Description
TDD RED task. Write failing tests that assert the post-implementation state BEFORE guard logic is added.

## Files to Create/Edit
1. tests/scripts/test-ticket-health-guards.sh (CREATE) — tests for shared helpers only:
   - test_ticket_read_status_returns_current_status
   - test_ticket_find_open_children_lists_children

2. tests/scripts/test-ticket-transition.sh (EDIT — append RED tests):
   - test_transition_bug_close_requires_reason
   - test_transition_bug_close_with_reason_succeeds
   - test_transition_close_blocked_with_open_children

3. tests/scripts/test-ticket-create.sh (EDIT — append RED test):
   - test_create_with_closed_parent_blocked

4. tests/scripts/test-ticket-link.sh (EDIT — append RED tests):
   - test_link_depends_on_closed_target_blocked
   - test_link_relates_to_closed_target_allowed

## .test-index
APPEND to existing ticket-lib.sh entry (do NOT replace):
  plugins/dso/scripts/ticket-lib.sh: <existing entries>, tests/scripts/test-ticket-health-guards.sh [test_ticket_read_status_returns_current_status]

All tests must FAIL (RED) before T2-T5 run.

## ACCEPTANCE CRITERIA

- [ ] tests/scripts/test-ticket-health-guards.sh exists
  Verify: test -f tests/scripts/test-ticket-health-guards.sh
- [ ] test-ticket-health-guards.sh contains at least 2 test functions
  Verify: grep -c "^test_" tests/scripts/test-ticket-health-guards.sh | awk '{exit ($1 < 2)}'
- [ ] test-ticket-transition.sh contains RED guard tests
  Verify: grep -q "test_transition_bug_close_requires_reason" tests/scripts/test-ticket-transition.sh
- [ ] test-ticket-create.sh contains RED guard test
  Verify: grep -q "test_create_with_closed_parent_blocked" tests/scripts/test-ticket-create.sh
- [ ] test-ticket-link.sh contains RED guard tests
  Verify: grep -q "test_link_depends_on_closed_target_blocked" tests/scripts/test-ticket-link.sh
- [ ] .test-index entry appended for ticket-lib.sh with RED marker
  Verify: grep -q "test-ticket-health-guards" .test-index


**2026-03-23T17:38:45Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T17:39:13Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T17:41:10Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-23T17:41:11Z**

CHECKPOINT 4/6: Implementation complete ✓ (TDD RED task — tests ARE the implementation)

**2026-03-23T17:41:35Z**

CHECKPOINT 5/6: Validation passed ✓ — all 4 files syntactically valid; health-guards runs RED (0 passed, 2 failed)

**2026-03-23T17:41:40Z**

CHECKPOINT 6/6: Done ✓ — All 6 acceptance criteria met. Files created/modified: tests/scripts/test-ticket-health-guards.sh (new), tests/scripts/test-ticket-transition.sh (appended tests 12-14), tests/scripts/test-ticket-create.sh (appended test 7), tests/scripts/test-ticket-link.sh (appended tests 10-11), .test-index (appended RED marker for ticket-lib.sh entry)
