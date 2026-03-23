---
id: dso-gfph
status: closed
deps: []
links: []
created: 2026-03-23T03:56:58Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-7mlx
---
# RED: Write failing tests for _phase_snapshot in cutover migration script

Write failing tests for the _phase_snapshot phase implementation in plugins/dso/scripts/cutover-tickets-migration.sh. The current stub only prints 'Running phase: snapshot' with no actual behavior.

TDD REQUIREMENT: Append 3 failing tests to tests/scripts/test-cutover-tickets-migration.sh. All must FAIL (RED) before Task 2 begins.

Tests to write:

1. test_phase_snapshot_writes_snapshot_file
   Setup: temp git repo fixture with 2 minimal .tickets/*.md files (write frontmatter directly, bypassing tk).
   Env: CUTOVER_SNAPSHOT_FILE pointing to temp path; CUTOVER_STATE_FILE pointing to temp path.
   Run: bash cutover-tickets-migration.sh --repo-root=FIXTURE (full run).
   Assert: CUTOVER_SNAPSHOT_FILE exists on disk after exit 0.
   RED: fails because _phase_snapshot stub writes no snapshot file.

2. test_phase_snapshot_captures_ticket_count
   Setup: fixture with exactly 3 .tickets/*.md files.
   Run: full run with CUTOVER_SNAPSHOT_FILE set.
   Assert: snapshot JSON file contains 'ticket_count' field equal to 3.
   RED: fails for same reason.

3. test_phase_snapshot_captures_full_tk_show_output
   Setup: fixture with 1 .tickets/dso-test1.md containing known title.
   Run: full run with CUTOVER_SNAPSHOT_FILE set.
   Assert: snapshot JSON 'tickets' array contains entry with id=dso-test1 and the captured tk show output.
   RED: fails for same reason.

Note: CUTOVER_SNAPSHOT_FILE is a new env var (default: /tmp/cutover-snapshot-$(date +%Y%m%dT%H%M%S).json) that will be introduced in Task 2 (implementation). Tests should set it explicitly to a known temp path for deterministic assertions.

File to edit: tests/scripts/test-cutover-tickets-migration.sh

## Acceptance Criteria

- [ ] bash tests/scripts/test-cutover-tickets-migration.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-cutover-tickets-migration.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] 3 new test functions for snapshot phase exist in test-cutover-tickets-migration.sh
  Verify: grep -c 'test_phase_snapshot' $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh | awk '{exit ($1 < 3)}'
- [ ] All 3 new snapshot tests FAIL before Task 2 implementation (RED state verified)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'FAIL.*snapshot'


## Notes

**2026-03-23T04:01:54Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T04:02:08Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T04:03:04Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-23T04:03:08Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T04:03:39Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-23T04:04:05Z**

CHECKPOINT 6/6: Done ✓ — AC verified: 3 snapshot test functions exist (test_phase_snapshot_writes_snapshot_file, test_phase_snapshot_captures_ticket_count, test_phase_snapshot_captures_full_tk_show_output); all 3 FAIL (RED) because _phase_snapshot stub writes no snapshot file; ruff check and ruff format --check both pass; bash syntax valid
