---
id: w20-pijg
status: closed
deps: [w20-rpdy]
links: []
created: 2026-03-21T16:24:41Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-6k7v
---
# Integration test: _sync_events round-trip between two local repos

Create tests/scripts/test-tk-sync-events-integration.sh with 4 integration test scenarios.

TDD exemption: Integration test written after implementation — this IS the integration test for the git remote boundary. Exemption criterion: existing coverage (none — this test IS the coverage) not applicable; instead citing Integration Test Task Rule: integration tests may be written after the implementation task.

Setup: bare origin repo + two local clones, each with .tickets-tracker/ worktree on tickets branch.

Test 1 (basic push/pull): Repo A writes event file directly → commits to tickets branch → tk sync-events from repo B → event file present in B's .tickets-tracker/

Test 2 (divergent merge): Both repos independently write different event files without syncing → tk sync-events from A (push) → tk sync-events from B (fetch + merge + push) → both event files present in both repos

Test 3 (flock not held during fetch): sync-events with a slow fetch (mock git fetch sleeps 0.2s) → .ticket-write.lock is NOT locked during fetch phase (verified by a concurrent writer succeeding during the sleep)

Test 4 (push retry): First push fails with exit 128 (simulated via mock git) → second attempt succeeds after re-fetch → event reaches remote

Each test must clean up tmp dirs on exit (trap EXIT).

Depends on: w20-rpdy (T4 implementation must be complete)


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Integration test script exists and is syntactically valid
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-tk-sync-events-integration.sh && bash -n $(git rev-parse --show-toplevel)/tests/scripts/test-tk-sync-events-integration.sh
- [ ] All 4 integration test scenarios pass
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-tk-sync-events-integration.sh
- [ ] Test script cleans up tmp dirs on exit (has EXIT trap)
  Verify: grep -q 'trap.*EXIT\|trap.*cleanup' $(git rev-parse --show-toplevel)/tests/scripts/test-tk-sync-events-integration.sh

## GAP ANALYSIS AMENDMENTS

- [ ] Integration test setup explicitly creates and pushes tickets branch to bare origin
  Verify: grep -q 'tickets.*branch\|push.*tickets\|branch.*tickets' $(git rev-parse --show-toplevel)/tests/scripts/test-tk-sync-events-integration.sh
- [ ] Setup creates .tickets-tracker/ git worktree on tickets branch in both clones
  Verify: grep -q 'tickets-tracker\|worktree add' $(git rev-parse --show-toplevel)/tests/scripts/test-tk-sync-events-integration.sh
