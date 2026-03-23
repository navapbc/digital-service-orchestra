---
id: dso-710r
status: open
deps: [dso-otk0]
links: []
created: 2026-03-23T00:22:57Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2a9w
---
# Implement cutover script skeleton: phase gates, timestamped log, dry-run flag

Implement plugins/dso/scripts/cutover-tickets-migration.sh — the phase-gate skeleton including:
1. Phase constants: PRE_FLIGHT, MIGRATE, VALIDATE, REFERENCE_UPDATE, CLEANUP (ordered array)
2. Phase gate loop: iterate phases sequentially, call phase handler stub (initially: echo phase name and exit 0)
3. Timestamped log file: create at CUTOVER_LOG_DIR (default: /tmp) with filename cutover-$(date +%Y-%m-%dT%H-%M-%S).log; redirect all output to both stdout and log file (tee or similar)
4. Dry-run mode: if --dry-run flag present, prefix all phase output lines with '[DRY RUN]'; do NOT write state file; execute phase stubs but skip any git-modifying actions
5. Argument parsing: support --dry-run, --help flags; --help prints usage with phase list and exits 0
6. State file: after each phase succeeds in non-dry-run mode, append completed phase name to /tmp/cutover-state-$(date +%Y-%m-%dT%H-%M-%S).json (or use a fixed path like /tmp/cutover-tickets-migration-state.json keyed by run timestamp)
7. Error handling: set -euo pipefail; if any phase exits non-zero, print 'ERROR: phase PHASE_NAME failed — see LOG_PATH' to stderr and exit non-zero

Pattern: follow merge-to-main.sh phase-gate approach (plugins/dso/scripts/merge-to-main.sh). Resolve REPO_ROOT via git rev-parse --show-toplevel. Script must be standalone (no CLAUDE_PLUGIN_ROOT dependency for its own operation).

Phase handler stubs: each phase function (e.g., _phase_pre_flight, _phase_migrate, etc.) logs 'Running phase: PHASE_NAME' and exits 0. Actual migration logic will be added by sibling stories (w21-7mlx, w21-wbqz, w21-25mq).

Test injection hook (required for T3 rollback tests): the script must support a CUTOVER_PHASE_EXIT_OVERRIDE env var (format: "PHASE_NAME=EXIT_CODE", e.g., "MIGRATE=1") that causes the named phase to exit with the specified code instead of its normal logic. This allows tests to inject failures without modifying the script. If the env var is not set, normal behavior applies. Example: CUTOVER_PHASE_EXIT_OVERRIDE="VALIDATE=1" causes the VALIDATE phase to exit 1.

TDD FIRST: implement only after T1 tests are confirmed RED.

## Acceptance Criteria

- [ ] plugins/dso/scripts/cutover-tickets-migration.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] Script has --help output listing all 5 phases
  Verify: $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh --help 2>&1 | grep -q 'PRE_FLIGHT\|MIGRATE\|VALIDATE\|REFERENCE_UPDATE\|CLEANUP'
- [ ] Script accepts --dry-run flag without error
  Verify: { cd /tmp && bash -c 'CUTOVER_LOG_DIR=/tmp $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh --dry-run'; true; }
- [ ] bash -n syntax check passes
  Verify: bash -n $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] test_cutover_phases_execute_in_order PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_phases_execute_in_order'
- [ ] test_cutover_creates_log_file_with_timestamp PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_creates_log_file_with_timestamp'
- [ ] test_cutover_dry_run_flag_produces_output_without_creating_state_file PASSES
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -q 'PASS.*test_cutover_dry_run_flag_produces_output_without_creating_state_file'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] CUTOVER_PHASE_EXIT_OVERRIDE env var causes named phase to exit with specified code
  Verify: CUTOVER_PHASE_EXIT_OVERRIDE="PRE_FLIGHT=1" CUTOVER_LOG_DIR=/tmp $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh 2>&1; test $? -ne 0

