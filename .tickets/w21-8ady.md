---
id: w21-8ady
status: open
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
