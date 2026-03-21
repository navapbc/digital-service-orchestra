---
id: w21-gyn8
status: open
deps: [w21-mtvm, w21-m4i9]
links: []
created: 2026-03-21T00:53:31Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ablv
---
# RED: Write failing test test_ticket_create_writes_create_event_atomically


## Description

Write failing shell tests for `ticket create` command.
Test file: `tests/scripts/test-ticket-create.sh`

### Test functions to write (all must FAIL before implementation):
1. `test_ticket_create_outputs_ticket_id` — assert that `ticket create task "My ticket"` prints a non-empty ticket ID to stdout matching pattern `[a-z0-9]+-[a-z0-9]+` (collision-resistant short ID)
2. `test_ticket_create_writes_create_event_json` — assert that after `ticket create`, exactly one `*-CREATE.json` file exists in `.tickets-tracker/<ticket_id>/` and it parses as valid JSON
3. `test_ticket_create_event_has_required_fields` — assert the CREATE event JSON contains: `timestamp` (integer), `uuid` (string), `event_type` = "CREATE", `env_id` (string), `author` (string), `data.ticket_type` (string), `data.title` (string)
4. `test_ticket_create_event_uses_python_json` — assert the event JSON was written via Python (no bash heredoc artifacts: no literal `\n`, no unescaped quotes in title containing special chars like `"it's a "quoted" title"`)
5. `test_ticket_create_auto_commits_to_tickets_branch` — assert that `git -C .tickets-tracker log --oneline -1` shows a commit referencing the created ticket ID after `ticket create`
6. `test_ticket_create_rejects_invalid_ticket_type` — assert that `ticket create invalid_type "title"` exits non-zero with an error message

### Test setup:
- Each test creates a fresh temp git repo and runs `ticket init` first (to set up .tickets-tracker/)
- Tests source `ticket-lib.sh` where needed

## TDD Requirement
RED: All 6 test functions must return non-zero before `ticket create` is implemented.
Verify RED: `bash tests/scripts/test-ticket-create.sh 2>&1; test $? -ne 0`

## Acceptance Criteria
- [ ] `bash tests/run-all.sh` passes (exit 0) — existing tests still green; new test is RED
  Verify: `bash $(git rev-parse --show-toplevel)/tests/run-all.sh`
- [ ] Test file exists at `tests/scripts/test-ticket-create.sh`
  Verify: `test -f $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-create.sh`
- [ ] Test file contains at least 6 test functions
  Verify: `grep -c 'test_ticket_create' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-create.sh | awk '{exit ($1 < 6)}'`
- [ ] Running the new test returns non-zero (RED)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-create.sh 2>&1; test $? -ne 0`
