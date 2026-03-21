---
id: dso-2igj
status: in_progress
deps: []
links: []
created: 2026-03-21T16:08:30Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-k2yz
---
# RED: LINK/UNLINK event write tests for ticket-link.sh

## Description

Write failing tests (RED phase) for `ticket link` and `ticket unlink` subcommands before implementing them.

**Files to create:**
- `tests/scripts/test-ticket-link.sh` — shell integration tests asserting:
  1. `ticket link <id1> <id2> blocks` creates a LINK event file in `.tickets-tracker/<id1>/` with `event_type=LINK`, `data.relation=blocks`, `data.target_id=<id2>`
  2. `ticket link <id2> <id1> depends_on` creates LINK event in `.tickets-tracker/<id2>/`
  3. `ticket unlink <id1> <id2>` creates an UNLINK event in `.tickets-tracker/<id1>/` referencing the original LINK uuid via `data.link_uuid`
  4. Linking to a nonexistent ticket exits nonzero
  5. Duplicate link (same id pair, same relation) is idempotent — no duplicate LINK event written on second call
  6. `ticket link` with <2 args exits nonzero with usage message
  7. `ticket link <id1> <id2> relates_to` creates bidirectional LINK events (events in both ticket dirs)

NOTE: Cycle detection tests are NOT part of ticket-link.sh's test suite — cycle detection is implemented in ticket-graph.py (dso-dr38) and tested in test_ticket_graph.py (dso-zej9). The `ticket link` cycle rejection path is tested in the E2E test (dso-ofdp) after dso-jefv routes `ticket link` through ticket-graph.py.

These tests MUST FAIL before `ticket-link.sh` is implemented (RED state).

**TDD Requirement (RED):** Write tests first, confirm: `bash tests/scripts/test-ticket-link.sh` exits nonzero. Then implementation task (dso-2igj's blocker) can begin.

## Acceptance Criteria

- [ ] `tests/scripts/test-ticket-link.sh` exists and is executable
  Verify: `test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-link.sh`
- [ ] All tests in `test-ticket-link.sh` fail before implementation (RED state confirmed)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-link.sh; test $? -ne 0`
- [ ] `ruff check` passes (exit 0) — no Python files modified by this task
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0) — existing tests still green
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`
