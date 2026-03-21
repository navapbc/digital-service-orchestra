---
id: dso-4cb7
status: open
deps: [dso-yaao]
links: []
created: 2026-03-21T16:09:44Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-goqp
---
# Implement hook_tickets_tracker_guard in pre-edit-write-functions.sh (Edit/Write)

Implement hook_tickets_tracker_guard in plugins/dso/hooks/lib/pre-edit-write-functions.sh.

Behavior:
- Only fires on Edit or Write tool calls
- Extracts file_path from tool_input
- If file_path contains /.tickets-tracker/: return 2 (block) with message redirecting to ticket commands
- All other cases: return 0 (allow, fail-open)
- ERR trap pattern: log to hook-error-log.jsonl and return 0 (consistent with hook_cascade_circuit_breaker)

Error message format:
  BLOCKED [tickets-tracker-guard]: Direct edits to .tickets-tracker/ are not allowed.
  Use ticket commands (ticket create, ticket sync, etc.) instead.
  Direct edits bypass event sourcing invariants and may corrupt the event log.

Function signature follows existing hooks in the file (takes INPUT json as ).
Add guard: [[ ${_PRE_EDIT_WRITE_FUNCTIONS_LOADED} ]] pattern already handles idempotency.
Add the function after hook_title_length_validator.

TDD: Task dso-yaao RED tests must pass GREEN after this task.


## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] hook_tickets_tracker_guard function defined in pre-edit-write-functions.sh
  Verify: grep -q 'hook_tickets_tracker_guard' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/pre-edit-write-functions.sh
- [ ] Edit to .tickets-tracker/ path returns exit 2 (blocked)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh
- [ ] Edit to non-.tickets-tracker/ path returns exit 0 (allowed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh
- [ ] Error message contains redirect to ticket commands
  Verify: source $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/pre-edit-write-functions.sh && echo '{"tool_name":"Edit","tool_input":{"file_path":"/repo/.tickets-tracker/foo.json"}}' | hook_tickets_tracker_guard - 2>&1 | grep -q 'ticket'
- [ ] ruff check plugins/dso/scripts/*.py tests/**/*.py passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
