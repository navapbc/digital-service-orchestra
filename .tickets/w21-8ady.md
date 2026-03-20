---
id: w21-8ady
status: closed
deps: []
links: []
created: 2026-03-20T01:21:28Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-vydt
---
# RED: Tests for child count in sprint-list-epics.sh output


## Notes

**2026-03-20T01:21:46Z**

## Description
Add child ticket fixtures and 3 RED tests to tests/scripts/test-sprint-list-epics.sh:
1. Add child ticket fixtures with parent: references (e.g., 2 children for epic-c, 0 for epic-a). Update make_ticket() helper to support parent field.
2. test_child_count_field_present — verify output includes a 4th tab-separated field
3. test_child_count_accuracy — verify epic with 2 children shows count 2
4. test_child_count_zero — verify childless epic shows count 0
All 3 FAIL (RED) because sprint-list-epics.sh doesn't output child counts yet.

TDD: These ARE the RED tests.

## ACCEPTANCE CRITERIA

- [ ] tests/scripts/test-sprint-list-epics.sh contains test_child_count_field_present
  Verify: grep -q "test_child_count_field_present" tests/scripts/test-sprint-list-epics.sh
- [ ] tests/scripts/test-sprint-list-epics.sh contains test_child_count_accuracy
  Verify: grep -q "test_child_count_accuracy" tests/scripts/test-sprint-list-epics.sh
- [ ] tests/scripts/test-sprint-list-epics.sh contains test_child_count_zero
  Verify: grep -q "test_child_count_zero" tests/scripts/test-sprint-list-epics.sh
- [ ] Test file contains at least 3 new test functions for child count
  Verify: grep -c "test_child_count" tests/scripts/test-sprint-list-epics.sh | awk '{exit ($1 < 3)}'
- [ ] All 3 child count tests FAIL (RED) when run
  Verify: bash tests/scripts/test-sprint-list-epics.sh 2>&1 | grep -q "FAILED"

## File Impact

### Files to modify
- tests/scripts/test-sprint-list-epics.sh (add fixtures and 3 RED tests)

**2026-03-20T19:10:29Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T19:10:49Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T19:11:55Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T19:11:58Z**

CHECKPOINT 4/6: Implementation complete ✓ (test-only task, no production code changes)

**2026-03-20T19:12:14Z**

CHECKPOINT 5/6: Validation passed ✓ — bash syntax OK; 14 existing tests pass, 3 new RED tests FAIL as expected (sprint-list-epics.sh does not yet output child counts)

**2026-03-20T19:12:32Z**

CHECKPOINT 6/6: Done ✓ — all 5 AC verified: test_child_count_field_present present, test_child_count_accuracy present, test_child_count_zero present, 3+ child_count test functions, FAILED appears in test output
