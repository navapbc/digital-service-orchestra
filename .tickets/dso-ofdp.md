---
id: dso-ofdp
status: open
deps: [dso-jefv]
links: []
created: 2026-03-21T16:09:23Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-k2yz
---
# E2E integration test for full dependency link/deps/cycle flow

## Description

Write an end-to-end integration test that exercises the full dependency flow: creating tickets, linking them, querying deps, verifying ready_to_work, and cycle rejection.

**Files to create:**
- `tests/scripts/test-ticket-dependency-e2e.sh` — E2E shell test asserting the full user-visible workflow:

  **Scenario 1 — Happy path blocking:**
  1. `ticket create task "Task A"` → `tkt-A`
  2. `ticket create task "Task B"` → `tkt-B`
  3. `ticket link tkt-B tkt-A blocks` → creates LINK event
  4. `ticket deps tkt-B` → JSON with `ready_to_work=false`, `blockers=["tkt-A"]`
  5. `ticket transition tkt-A open in_progress` then `ticket transition tkt-A in_progress closed`
  6. `ticket deps tkt-B` → JSON with `ready_to_work=true`, `blockers=[]`

  **Scenario 2 — Cycle rejection:**
  1. `ticket create task "X"`, `ticket create task "Y"`
  2. `ticket link X Y blocks` succeeds
  3. `ticket link Y X blocks` → exits nonzero (cycle detected)

  **Scenario 3 — Tombstone-awareness:**
  1. `ticket create task "Z1"`, `ticket create task "Z2"`
  2. `ticket link Z2 Z1 blocks` → `ready_to_work=false`
  3. Manually remove `.tickets-tracker/Z1/` (simulate archiving)
  4. `ticket deps Z2` → `ready_to_work=true` (tombstoned blocker treated as closed)

  **Scenario 4 — Unlink:**
  1. Link B→A; confirm `ready_to_work=false`
  2. `ticket unlink B A`
  3. `ticket deps B` → `ready_to_work=true` (dep removed)

**TDD note:** This is an integration test written after all implementation tasks are complete. Exemption: Integration exemption — this task tests cross-boundary flow across all implementation tasks; it cannot run in RED state against the not-yet-implemented stack. Written after dso-jefv (all implementation complete).

## Acceptance Criteria

- [ ] `tests/scripts/test-ticket-dependency-e2e.sh` exists and is executable
  Verify: `test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-dependency-e2e.sh`
- [ ] Happy path blocking scenario passes
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-dependency-e2e.sh`
- [ ] Cycle rejection scenario passes
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-dependency-e2e.sh`
- [ ] Tombstone-awareness scenario passes
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-dependency-e2e.sh`
- [ ] Unlink scenario passes
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-dependency-e2e.sh`
- [ ] `ruff check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`
