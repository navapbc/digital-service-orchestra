---
id: w21-1mgj
status: closed
deps: []
links: []
created: 2026-03-19T20:48:34Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-ycsr
---
# RED: test tk create rejects duplicate title

Write tests/scripts/test-tk-create-title-dedup.sh. In a temp TICKETS_DIR, call tk create "My Title", capture ID. Call tk create "My Title" again. Assert: second exits non-zero AND stderr contains first ticket's ID.

TDD: Fails because cmd_create has no title dedup check. Isolated via temp TICKETS_DIR.

test-exempt from universal criteria at RED phase (test must fail).

## Acceptance Criteria

- [ ] Test file exists
  Verify: test -f tests/scripts/test-tk-create-title-dedup.sh
- [ ] Test body asserts duplicate rejection
  Verify: grep -q 'duplicate\|already exists\|non.zero' tests/scripts/test-tk-create-title-dedup.sh
- [ ] Running the test FAILS (RED)
  Verify: ! bash tests/scripts/test-tk-create-title-dedup.sh


## Notes

**2026-03-19T21:04:23Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T21:05:00Z**

CHECKPOINT 2/6: Code patterns understood ✓ — cmd_create at line 424 in tk script has no title dedup check; test pattern follows test-tk-dep-rm.sh conventions

**2026-03-19T21:05:35Z**

CHECKPOINT 3/6: Tests written ✓ — tests/scripts/test-tk-create-title-dedup.sh created with 3 tests: duplicate rejection (RED), distinct titles accepted, exact case match

**2026-03-19T21:05:44Z**

CHECKPOINT 4/6: Implementation complete ✓ — RED phase: no implementation; test is designed to fail because cmd_create has no title dedup guard

**2026-03-19T21:06:19Z**

CHECKPOINT 5/6: Validation passed ✓ — AC1: file exists, AC2: pattern found, AC3: test fails (RED) with 1 PASS / 2 FAIL as expected

**2026-03-19T21:06:26Z**

CHECKPOINT 6/6: Done ✓ — All ACs verified. RED phase complete. test-tk-create-title-dedup.sh ready for GREEN phase (w21-r8rd).
