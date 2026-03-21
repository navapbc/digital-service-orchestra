---
id: dso-97wx
status: closed
deps: [dso-woj0, dso-lrpv]
links: []
created: 2026-03-21T04:57:08Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# Implement ticket-list.sh (compile all tickets via reducer, output JSON array)

Create plugins/dso/scripts/ticket-list.sh that compiles all tickets in .tickets-tracker/ via the reducer and outputs a JSON array of current states.

Implementation:

File: plugins/dso/scripts/ticket-list.sh

Usage: ticket list
  Output: JSON array of compiled ticket states to stdout (one per line is fine, but valid JSON array preferred)
  Errors go to stderr; exit 0 on success (even if some tickets have errors)

Algorithm:
1. Locate TRACKER_DIR=$REPO_ROOT/.tickets-tracker/
2. For each subdirectory in TRACKER_DIR that is not hidden (does not start with .):
   - Run python3 ticket-reducer.py <ticket_dir> 2>/dev/null
   - If exit 0: collect JSON output
   - If exit non-zero (no CREATE event): collect error-state dict {'ticket_id': <id>, 'status': 'error', 'error': 'no_create_event'}
3. Assemble all collected states into a JSON array via python3 json.dumps()
4. Print the JSON array to stdout

Edge cases:
- Empty tracker (no ticket subdirs): output []
- Ticket dir with zero valid events: include error-state in output, do not crash
- Ticket dir with corrupt CREATE: reducer returns fsck_needed state, include in output
- Error reading a ticket dir (permissions, etc.): skip with stderr warning, do not crash

All JSON assembly via python3 json.dumps() — never bash string concatenation.

TDD Requirement: Run tests/scripts/test-ticket-list.sh. All tests from dso-woj0 must pass (GREEN) after this task.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] plugins/dso/scripts/ticket-list.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-list.sh
- [ ] All tests from dso-woj0 pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-list.sh
- [ ] ticket list with empty tracker outputs valid JSON empty array
  Verify: output=$(bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-list.sh 2>/dev/null || echo '[]'); python3 -c "import json,sys; data=json.loads(sys.argv[1]); assert isinstance(data, list)" "$output"
- [ ] ticket list outputs are assembled via python3 json.dumps (no bash string concat)
  Verify: grep -v 'json.dumps\|python3' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-list.sh | grep -v '#' | grep -qv 'echo.*\[.*\]' || true

## Notes

**2026-03-21T05:36:30Z**

## Gap Analysis Amendment (dso-lrpv)

ticket-list.sh must handle both reducer exit codes:
1. Exit 0: parse JSON, include in output (even if status='error' or 'fsck_needed')
2. Exit non-zero: construct fallback {ticket_id, status: 'error', error: 'reducer_failed'}

This ensures no tickets are silently dropped from listing.

**2026-03-21T06:00:55Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T06:01:23Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T06:02:22Z**

CHECKPOINT 3/6: Tests written (pre-existing) ✓

**2026-03-21T06:02:22Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T06:15:09Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T06:32:04Z**

CHECKPOINT 6/6: Done ✓ — ticket-list.sh. Tests: 10 passed, 0 failed.
