---
id: dso-si1e
status: in_progress
deps: [dso-dr38]
links: []
created: 2026-03-21T16:09:12Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-k2yz
---
# RED: ticket deps subcommand CLI tests

## Description

Write failing tests (RED phase) for the `ticket deps` subcommand before implementing it.

**Files to create:**
- `tests/scripts/test-ticket-deps.sh` — shell integration tests asserting:
  1. `ticket deps <id>` prints JSON with keys `ticket_id`, `deps`, `blockers`, `ready_to_work`
  2. `ticket deps <id>` with no blockers returns `ready_to_work=true`
  3. `ticket deps <id>` with an open blocker returns `ready_to_work=false`
  4. `ticket deps <id>` with all blockers closed returns `ready_to_work=true`
  5. `ticket deps <nonexistent>` exits nonzero with error message
  6. `ticket deps` with no args exits nonzero with usage message
  7. `ticket deps <id>` output includes the blocker's ticket_id in `blockers` array when blockers are open

These tests MUST FAIL before `ticket deps` is wired in the dispatcher (RED state).

**TDD Requirement (RED):** Run: `bash tests/scripts/test-ticket-deps.sh` — expect failure (unknown subcommand error).

## Acceptance Criteria

- [ ] `tests/scripts/test-ticket-deps.sh` exists and is executable
  Verify: `test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-deps.sh`
- [ ] All tests in `test-ticket-deps.sh` fail before implementation (RED state confirmed)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-deps.sh; test $? -ne 0`
- [ ] `ruff check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0) — existing tests still green
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`
