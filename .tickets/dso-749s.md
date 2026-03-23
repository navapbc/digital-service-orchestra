---
id: dso-749s
status: open
deps: [dso-dr2k, dso-gq8v]
links: []
created: 2026-03-23T00:24:38Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2a9w
---
# Implement cutover idempotent resume: write state file per phase, skip completed on re-run

Implement idempotent resume from state file in plugins/dso/scripts/cutover-tickets-migration.sh.

Design:
- State file path: CUTOVER_STATE_FILE env var (default: /tmp/cutover-tickets-migration-state.txt or derive from run timestamp)
- After each phase succeeds (in non-dry-run mode): append completed phase name to state file (one phase per line, or JSON array — choose one and keep consistent with T2's state file usage)
- On script startup: if --resume flag is passed, read state file; build set of completed_phases
- Phase loop: before running each phase, check if phase name is in completed_phases set; if yes, log 'Skipping completed phase: PHASE_NAME' and skip
- If ALL phases already completed: print 'All phases already completed — nothing to do' and exit 0
- Dry-run mode: do NOT write state file (already enforced in T2)

State file format: one phase name per line (simple, parseable with grep -q)

TDD FIRST: implement only after T5 tests are confirmed RED.

## Acceptance Criteria

- [ ] test_cutover_state_file_written_after_each_phase PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_state_file_written_after_each_phase'
- [ ] test_cutover_resume_skips_completed_phases PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_resume_skips_completed_phases'
- [ ] test_cutover_resume_does_not_rerun_already_completed_phase PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_resume_does_not_rerun_already_completed_phase'
- [ ] Script writes state file after each successful phase
  Verify: grep -q 'CUTOVER_STATE_FILE\|_state_file\|cutover.*state' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] Script reads state file on resume and skips completed phases
  Verify: grep -q 'resume\|--resume\|completed_phases\|skip.*phase\|phase.*skip' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py

