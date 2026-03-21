---
id: dso-ltwr
status: in_progress
deps: [dso-haj7]
links: []
created: 2026-03-21T07:10:40Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ay8w
---
# IMPL: Implement full concurrency stress test harness (5 sessions x 10 ops)

Implement the full concurrency stress test harness in tests/scripts/test-ticket-concurrency-stress.sh, replacing the RED stub with a complete working test.

TDD Requirement: This task depends on dso-haj7 (RED skeleton). The stub assert must be FAILING (RED) before this task begins. Implementing the full harness makes the test pass (GREEN).

Implementation Steps:
1. Implement a helper _make_stress_session() function that performs 10 mixed ticket operations (4 creates, 3 transitions, 3 comments) writing output to a temp dir. Each session's transitions and comments target ONLY tickets created by that same session (not cross-session) — avoids flakiness from ticket IDs not yet created by other sessions. Each operation records the ticket ID and event type to a log file in the temp dir.
2. Implement synchronized start using a barrier file: all 5 sessions wait on a shared ready-file before starting (touch a file per session, poll until all 5 exist, then all begin). Barrier polling must have a hard timeout of 30 seconds — if not all 5 sessions signal ready within 30 seconds, the waiting sessions must exit non-zero (fail fast, not hang). This prevents staggered-start from masking race conditions.
3. Launch 5 parallel background processes (using & and capturing all 5 PIDs separately). Each session runs _make_stress_session with a unique session index (1-5) and writes to its own temp dir.
4. Wait for all 5 processes individually (wait $pid1, wait $pid2, ...) and capture exit codes.
5. Assert all 5 sessions exited 0 (no errors under load).
6. Count total event files in .tickets-tracker/ across all ticket directories. Assert count >= 50 (CREATE + STATUS + COMMENT events across all sessions).
7. For each event file found: parse with python3 json.load, assert it is valid JSON, assert it has required fields (event_type, timestamp, uuid, env_id). Track which ticket_id owns each event.
8. Assert all 50 events are committed: check git log --oneline count >= 50 distinct commits in .tickets-tracker worktree.
9. Assert no bundling: verify no single git commit contains multiple event files from different sessions (git show --name-only for recent commits, check 1 file per commit).
10. Cache layer test: run ticket show on 3-5 sampled ticket IDs; assert each exits 0 and returns valid JSON (tests warm-cache read after concurrent writes).
11. Add tests/scripts/test-ticket-concurrency-stress.sh to tests/scripts/run-all.sh following existing test inclusion pattern. This is the first task where the test is registered — after dso-haj7 created the file without registering it.
12. Clean up all session temp dirs.

Behavioral constraints:
- Use process-level parallelism (bash subshells with &), never Python threads
- All session PIDs must be captured individually for accurate exit code tracking
- Temp dirs must be registered in _CLEANUP_DIRS for automatic cleanup
- flock serialization is already implemented in ticket-lib.sh; do NOT add additional locking in the test

File path: tests/scripts/test-ticket-concurrency-stress.sh (replaces stub from dso-haj7)

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Stress test exits 0 (all 50 events verified, no data loss)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh
- [ ] Stress test verifies 50 events total exist in the event log
  Verify: grep -q '50' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh
- [ ] Each event file parses as valid JSON with correct expected fields (ticket_id, event_type, env_id, timestamp)
  Verify: grep -q 'valid JSON\|json.load' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh
- [ ] Each event is in a distinct git commit (no bundling of multiple sessions' events in one commit)
  Verify: grep -q 'distinct\|50.*commit\|commit.*50' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh
- [ ] Cache layer exercised: ticket show succeeds for sampled tickets after concurrent writes
  Verify: grep -q 'ticket.*show\|show.*ticket' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh
- [ ] 5 parallel session processes launched and tracked individually
  Verify: grep -c 'pid[0-9]\|PID[0-9]' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh | awk '{exit ($1 < 5)}'
- [ ] Barrier sync has a hard timeout (30 seconds) — test does not hang if a session fails to start
  Verify: grep -q 'deadline\|timeout.*30\|barrier.*timeout\|30.*barrier' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh
- [ ] Each session's transitions target only tickets created within that same session (no cross-session ticket references)
  Verify: grep -q 'session.*id\|created_by_session\|session_tickets\|local.*id' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-concurrency-stress.sh
- [ ] test-ticket-concurrency-stress.sh is registered in tests/scripts/run-all.sh
  Verify: grep -q 'test-ticket-concurrency-stress' $(git rev-parse --show-toplevel)/tests/scripts/run-all.sh

## Gap Analysis Amendments (applied during Step 6)

Gap #1 (Cross-Task Interference): dso-haj7 does NOT add stub to run-all.sh. This task (dso-ltwr) adds it after the full harness passes. Step 11 in implementation steps reflects this.

Gap #2 (Race Condition): Barrier sync must have a 30-second timeout to prevent infinite hang. Step 2 updated and AC added above.

Gap #3 (Implicit Assumption): Sessions must use only within-session ticket IDs for transitions/comments. Step 1 updated and AC added above.


## Notes

**2026-03-21T07:36:08Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T07:38:30Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T07:38:30Z**

CHECKPOINT 6/6: Done ✓
