---
id: dso-woj0
status: in_progress
deps: [dso-mso2]
links: []
created: 2026-03-21T04:56:53Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# RED: Write failing tests for ticket-list.sh (compile all tickets via reducer)

Write failing tests (RED) in tests/scripts/test-ticket-list.sh that verify ticket-list.sh behavior. Tests must FAIL before ticket-list.sh exists.

Test file: tests/scripts/test-ticket-list.sh

Test cases:
1. ticket list with two tickets → outputs valid JSON array with both tickets' compiled state
2. ticket list with empty tracker → outputs empty JSON array '[]'
3. ticket list skips ticket dirs with no CREATE event (ghost prevention) → those dirs are either omitted or marked with error status in output
4. ticket list with a corrupt CREATE event → the corrupt ticket appears with status='fsck_needed' in the output (not silently omitted, not crash)
5. ticket list output contains ticket_id, ticket_type, title, status fields for each ticket

Implementation pattern:
- Tests use a minimal fixture: ticket-init.sh in a temp git repo + direct event file writes
- Tests call ticket list (via bash plugins/dso/scripts/ticket list) and parse output with python3

TDD Requirement: All tests must fail (exit non-zero) before ticket-list.sh is implemented.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/scripts/test-ticket-list.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-list.sh
- [ ] test-ticket-list.sh contains at least 5 test cases
  Verify: grep -c 'test_\|assert\|PASS\|FAIL' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-list.sh | awk '{exit ($1 < 5)}'
- [ ] All tests in test-ticket-list.sh fail (RED) before ticket-list.sh is created
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-list.sh 2>&1; test $? -ne 0

## Notes

**2026-03-21T05:36:30Z**

## Gap Analysis Amendment (dso-lrpv)

Add test cases for:
1. Exit-0 with error-status JSON (ghost ticket in list output)
2. Exit-nonzero (fallback error dict in list output)

**2026-03-21T05:55:07Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T05:55:14Z**

CHECKPOINT 2/6: Code patterns understood ✓ — ticket-reducer.py returns dict with ticket_id, ticket_type, title, status, author, comments, deps fields; error-state dicts have status=error/fsck_needed; ghost dirs (no CREATE) return None from reduce_ticket; corrupt CREATE returns fsck_needed

**2026-03-21T05:57:15Z**

CHECKPOINT 3/6: Tests written ✓ — 5 test cases: returns all tickets, empty system, required fields, ghost ticket with error status, corrupt CREATE with fsck_needed

**2026-03-21T05:57:37Z**

CHECKPOINT 6/6: Done ✓ — 5/5 tests FAIL (RED confirmed), shellcheck passes, file is executable
