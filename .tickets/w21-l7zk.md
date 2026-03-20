---
id: w21-l7zk
status: closed
deps: [w21-dedx]
links: []
created: 2026-03-20T19:09:33Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-uqfn
---
# IMPL: Create record-test-status.sh (protected test status recorder)

Create plugins/dso/hooks/record-test-status.sh — the script invoked in COMMIT-WORKFLOW.md that discovers associated tests, runs them, and records the test-gate-status file.

Mirrors the structure of record-review.sh. Design:

Usage:
  record-test-status.sh [--source-file <path>]
  When --source-file is omitted, runs discovery for all staged source files.

Convention-based association algorithm:
  For each staged source file (e.g., plugins/dso/hooks/foo.sh or src/bar.py):
    basename=
    # Strip extension, add test_ prefix
    test_name="test_${basename%.*}"
    # Find in test directory tree
    associated=
    # Collect all matches

Execution:
  For each associated test file:
    Run: bash <test_file> 2>&1
    Capture exit code
    If exit 144 -> record exit_code=144, set status to 'timeout'
    If exit non-zero -> set status to 'failed'
  If no associated tests -> skip (no test-gate-status written; gate exempts this)
  If all pass -> status = 'passed'

Hash capture:
  IMPORTANT: Compute diff hash AFTER git add (staged state), same as record-review.sh.
  Use: bash "$HOOK_DIR/compute-diff-hash.sh"
  This matches the hash the gate computes at pre-commit time.

State file written to: $(get_artifacts_dir)/test-gate-status
Format:
  Line 1: 'passed' or 'failed' or 'timeout'
  Line 2: diff_hash=<sha256>
  Line 3: timestamp=<ISO8601>
  Line 4: tested_files=<comma-separated list of test files run>

Exit 144 handling:
  When any test runner exits 144 (SIGURG/timeout from test-batched.sh ceiling):
  - Print actionable error to stderr:
    'Test runner terminated (exit 144). Complete tests using test-batched.sh:'
    'bash plugins/dso/scripts/test-batched.sh --timeout=50 "bash tests/hooks/test-<name>.sh"'
    'Then resume with the NEXT: command printed by test-batched.sh.'
  - Record status as 'timeout' in test-gate-status
  - Exit non-zero so the commit workflow knows tests are incomplete

Implementation constraints:
  - Source plugins/dso/hooks/lib/deps.sh for get_artifacts_dir, hash_stdin
  - Script must be executable (chmod +x)
  - Use set -euo pipefail
  - Follow header comment pattern from record-review.sh

Error handling for edge cases:
  - Associated test file found but not executable: print warning to stderr and skip that file; do not abort discovery. If ALL associated files are non-executable, treat as exempt (no test-gate-status written).
  - Associated test file found but not a regular file (symlink, directory): skip with warning.
  These are defensive guards — convention-based lookup may find false matches in edge-case directory layouts.

## Acceptance Criteria

- [ ] plugins/dso/hooks/record-test-status.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/hooks/record-test-status.sh
- [ ] Script discovers and runs associated test file for foo.py -> test_foo.sh/py
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-record-test-status.sh 2>&1 | grep -q 'PASS.*test_discovers_associated_tests'
- [ ] Script records 'passed' and diff_hash when tests pass
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-record-test-status.sh 2>&1 | grep -q 'PASS.*test_records_passed_status'
- [ ] Script records failure status when tests fail
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-record-test-status.sh 2>&1 | grep -q 'PASS.*test_records_failed_status'
- [ ] Script prints actionable test-batched.sh guidance on exit 144
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-record-test-status.sh 2>&1 | grep -q 'PASS.*test_exit_144_actionable_message'
- [ ] diff_hash matches compute-diff-hash.sh output captured after staging
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-record-test-status.sh 2>&1 | grep -q 'PASS.*test_hash_matches\|PASS.*test_captures_hash'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh


## Notes

**2026-03-20T19:43:52Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T19:44:03Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T19:44:10Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓

**2026-03-20T19:45:16Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T19:50:27Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T19:51:48Z**

CHECKPOINT 6/6: Done ✓
