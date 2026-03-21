---
id: w21-ymip
status: open
deps: [w21-6bmd, w21-1plz]
links: []
created: 2026-03-21T00:55:13Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ablv
---
# Implement ticket show command (dispatcher + reducer invocation)


## Description

Implement `plugins/dso/scripts/ticket-show.sh` — the show subcommand — and update the `ticket` dispatcher to route `ticket show <id>` to it.

### Usage:
```
ticket show <ticket_id>
```

### Implementation steps:
1. Validate `ticket_id` is provided; exit 1 with usage message if not
2. Verify `.tickets-tracker/<ticket_id>/` directory exists; exit 1 with "Ticket <id> not found" if not
3. Call: `python3 "$(dirname "$0")/ticket-reducer.py" ".tickets-tracker/<ticket_id>"`
4. Capture output (JSON string of compiled state)
5. If reducer exits 1: print "Error: ticket <id> has no CREATE event" and exit 1
6. Pretty-print the JSON to stdout: `python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, ensure_ascii=False))"`

### Output format (human-readable):
```json
{
  "ticket_id": "a1b2-c3d4",
  "ticket_type": "task",
  "title": "My ticket title",
  "status": "open",
  "author": "Joe Oakhart",
  "created_at": 1710000000,
  "env_id": "...",
  "parent_id": null,
  "comments": [],
  "deps": []
}
```

### RED test to write (in `tests/scripts/test-ticket-show.sh`):
1. `test_ticket_show_displays_compiled_state` — after `ticket init` + `ticket create task "Test ticket"`, assert `ticket show <id>` exits 0 and outputs JSON with correct `ticket_type` = "task" and `title` = "Test ticket"
2. `test_ticket_show_fails_for_unknown_id` — assert `ticket show nonexistent-id` exits non-zero with "not found" in stderr
3. `test_ticket_show_output_is_valid_json` — assert output of `ticket show <id>` is parseable by `python3 -m json.tool`

Write these tests in `tests/scripts/test-ticket-show.sh` FIRST (RED), then implement the command (GREEN).
This task includes both the RED test file creation AND the implementation.

## TDD Requirement
RED: Write `tests/scripts/test-ticket-show.sh` first with the 3 failing tests above.
GREEN: Implement `ticket-show.sh` to make all 3 tests pass.
Note: This task bundles RED+GREEN because the test setup (init+create+show) requires both init and create to already work (T3, T7) — writing show tests in isolation is not possible without mocking the full worktree, which would make the test a change-detector.

Depends on: w21-6bmd (reducer), w21-1plz (init — to have a valid .tickets-tracker to test against)

## Acceptance Criteria
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/run-all.sh`
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `plugins/dso/scripts/ticket-show.sh` exists and is executable
  Verify: `test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-show.sh`
- [ ] Test file exists at `tests/scripts/test-ticket-show.sh`
  Verify: `test -f $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-show.sh`
- [ ] `ticket show` test suite passes (all 3 assertions green)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-show.sh`
- [ ] `ticket show` on unknown ID exits non-zero
  Verify: `bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-show.sh nonexistent-0000 2>/dev/null; test $? -ne 0`

## Gap Analysis Amendments (from Step 6)

**AC Amendment — RED phase verification before implementation:**
- [ ] Before implementing ticket-show.sh: `bash tests/scripts/test-ticket-show.sh` returns non-zero (RED — show command not yet implemented)
  Verify: Write tests/scripts/test-ticket-show.sh → run it → confirm non-zero exit → THEN implement ticket-show.sh
  Rationale: T10 bundles RED+GREEN because show tests require a real .tickets-tracker (init+create must exist). The sub-agent must follow the RED→GREEN sequence within this task: write the test first, verify it fails, then implement. This criterion enforces that sequence.
