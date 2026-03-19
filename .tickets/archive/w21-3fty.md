---
id: w21-3fty
status: closed
deps: []
links: []
created: 2026-03-19T20:49:35Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-ycsr
---
# RED: test archive parent-child protection

Write tests/scripts/test-archive-parent-child-protection.sh. In temp TICKETS_DIR:
1. Create closed epic "epic-001" with deps:[] (NO deps relationship)
2. Create open child "child-001" with parent: epic-001 and deps:[]
3. Run archive-closed-tickets.sh with TICKETS_DIR override
4. Assert: epic-001.md NOT in archive/ AND stderr contains "child-001"

Also add deps-path regression fixture: closed ticket "dep-prot-001" with deps:[open-001], open ticket "open-001". Assert dep-prot-001 NOT archived (existing deps protection still works).

Fixture deliberately has NO deps between parent and child — only parent field — so test fails against current deps-only implementation.

TDD: Fails because archive script doesn't check parent field.

## Acceptance Criteria

- [ ] Test file exists
  Verify: test -f tests/scripts/test-archive-parent-child-protection.sh
- [ ] Test body references parent-child fixture
  Verify: grep -q 'parent.*epic-001\|child-001' tests/scripts/test-archive-parent-child-protection.sh
- [ ] Running the test FAILS (RED)
  Verify: ! bash tests/scripts/test-archive-parent-child-protection.sh


## Notes

**2026-03-19T21:04:22Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T21:04:50Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T21:05:24Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T21:05:52Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED test only — no implementation changes per task spec)

**2026-03-19T21:06:11Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-19T21:06:11Z**

CHECKPOINT 6/6: Done ✓
