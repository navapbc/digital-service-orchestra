---
id: w21-8vlg
status: closed
deps: []
links: []
created: 2026-03-20T19:13:37Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-uqfn
---
# RED: Write failing tests for test-gate bypass protection in review-gate-bypass-sentinel.sh

Write tests for the new bypass protection patterns (Pattern g: test-gate-status write block, Pattern h: test-gate-status rm block) in review-gate-bypass-sentinel.sh BEFORE implementing T7.

Add to tests/hooks/test-review-gate-bypass-sentinel.sh (extend existing file, do NOT create a new file — the bypass sentinel test file already exists):

1. test_test_gate_status_direct_write_blocked:
   A command like 'echo passed > /tmp/.../test-gate-status' is blocked by hook_review_bypass_sentinel.
   Returns 2 (block). Error message mentions 'test-gate-status' and 'record-test-status.sh'.

2. test_test_gate_status_rm_blocked:
   A command like 'rm /tmp/.../test-gate-status' is blocked by hook_review_bypass_sentinel.
   Returns 2 (block).

3. test_record_test_status_sh_not_blocked:
   A command calling 'bash plugins/dso/hooks/record-test-status.sh' is NOT blocked.
   Returns 0 (allow).

4. test_test_gate_status_read_not_blocked:
   A command like 'cat /tmp/.../test-gate-status' is NOT blocked (read-only).
   Returns 0 (allow).

TDD requirement: All 4 tests MUST FAIL before T7's implementation (the new Pattern g/h code). Confirm RED state by running the tests against the unmodified bypass sentinel.

The existing test file is at: tests/hooks/test-review-gate-bypass-sentinel.sh
Add the new test functions to that file — do not create a new test file.

## Acceptance Criteria

- [ ] tests/hooks/test-review-gate-bypass-sentinel.sh contains test_test_gate_status_direct_write_blocked
  Verify: grep -q 'test_test_gate_status_direct_write_blocked' $(git rev-parse --show-toplevel)/tests/hooks/test-review-gate-bypass-sentinel.sh
- [ ] tests/hooks/test-review-gate-bypass-sentinel.sh contains test_record_test_status_sh_not_blocked
  Verify: grep -q 'test_record_test_status_sh_not_blocked' $(git rev-parse --show-toplevel)/tests/hooks/test-review-gate-bypass-sentinel.sh
- [ ] New tests fail when Pattern g/h are not yet implemented (RED state)
  Verify: grep -q 'test_test_gate_status_direct_write_blocked\|test_test_gate_status_rm_blocked' $(git rev-parse --show-toplevel)/tests/hooks/test-review-gate-bypass-sentinel.sh
- [ ] bash tests/run-all.sh passes (existing bypass sentinel tests still green)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh


## Notes

**2026-03-20T19:17:27Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T19:17:48Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T19:18:25Z**

CHECKPOINT 3/6: Tests written ✓ — 4 new tests added, all in RED state (4 fail, 21 existing pass)

**2026-03-20T19:18:26Z**

CHECKPOINT 4/6: Implementation complete ✓ — RED tests only, no implementation needed for this task

**2026-03-20T19:21:40Z**

CHECKPOINT 5/6: Validation passed ✓ — 21 existing tests pass, 4 new RED tests fail as expected (Pattern g/h not yet implemented). Full run-all.sh exits 1 due to intentional RED tests.

**2026-03-20T19:22:02Z**

CHECKPOINT 6/6: Done ✓

**2026-03-20T19:24:10Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/hooks/test-review-gate-bypass-sentinel.sh. Tests: 21 pass, 4 RED (intentional).
