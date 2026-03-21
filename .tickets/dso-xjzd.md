---
id: dso-xjzd
status: open
deps: [dso-mso2]
links: []
created: 2026-03-21T04:57:42Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# RED: Write failing tests for ticket-comment.sh (append COMMENT event + ghost prevention)

Write failing tests (RED) in tests/scripts/test-ticket-comment.sh. All tests must FAIL before ticket-comment.sh exists.

File: tests/scripts/test-ticket-comment.sh

Test cases:
1. Happy path: ticket comment <id> 'my note' → exits 0, COMMENT event file written with correct body and auto-committed
2. Ghost prevention: comment on nonexistent ticket_id → exits non-zero with clear error
3. Ghost prevention: comment on ticket dir with no CREATE event → exits non-zero with clear error
4. Empty body rejection: ticket comment <id> '' → exits non-zero (empty comment body not allowed)
5. Multiple comments accumulate: after two comments, ticket show reveals comments list with both entries in order
6. COMMENT event file format: verify the written JSON contains event_type='COMMENT', data.body=<body>, env_id, author, timestamp fields

Implementation pattern:
- Tests use minimal fixture: ticket init in temp repo + ticket create
- Call bash plugins/dso/scripts/ticket comment <id> 'comment text'
- Verify COMMENT event file exists in .tickets-tracker/<id>/

TDD Requirement: All tests must fail (exit non-zero) before ticket-comment.sh is implemented.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/scripts/test-ticket-comment.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-comment.sh
- [ ] test-ticket-comment.sh contains at least 6 test cases
  Verify: grep -c 'PASS\|FAIL\|assert\|test_' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-comment.sh | awk '{exit ($1 < 6)}'
- [ ] All tests in test-ticket-comment.sh fail (RED) before ticket-comment.sh is created
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-comment.sh 2>&1; test $? -ne 0
