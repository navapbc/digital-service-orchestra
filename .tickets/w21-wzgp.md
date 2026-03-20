---
id: w21-wzgp
status: open
deps: [w21-v5i4]
links: []
created: 2026-03-20T19:08:50Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-uqfn
---
# IMPL: Create pre-commit-test-gate.sh (Layer 1 git pre-commit hook)

Create plugins/dso/hooks/pre-commit-test-gate.sh — the git pre-commit hook that enforces test gate verification for staged source files.

Mirrors the structure of pre-commit-review-gate.sh exactly. Design:

1. Get staged files via git diff --cached --name-only
2. For each staged .py source file (not test files themselves), run convention-based association lookup:
   - foo.py -> search test directory tree for test_foo.py (find test dirs for all matches)
   - Files with no associated test are exempt (pass the gate without blocking)
3. For files with associated tests, check $ARTIFACTS_DIR/test-gate-status:
   a. If test-gate-status file is absent -> exit 1 with structured error (MISSING)
   b. Read first line: must be 'passed' -> else exit 1 (NOT_PASSED)
   c. Read diff_hash line: compute current staged diff hash via compute-diff-hash.sh -> compare
      If mismatch -> exit 1 (HASH_MISMATCH)
4. All checks pass -> exit 0

Error messages must be actionable:
- MISSING: 'BLOCKED: test gate — no test-status recorded. Run record-test-status.sh or use /dso:commit'
- HASH_MISMATCH: 'BLOCKED: test gate — code changed since tests were recorded. Re-run record-test-status.sh'
- NOT_PASSED: 'BLOCKED: test gate — tests did not pass. Fix failures before committing'
- If test runner returned exit 144, include: 'Run: plugins/dso/scripts/test-batched.sh --timeout=50 "<test cmd>"'

Implementation constraints:
- Source plugins/dso/hooks/lib/deps.sh for get_artifacts_dir, hash_stdin
- Reuse compute-diff-hash.sh for hash computation (same as review gate)
- State file: $ARTIFACTS_DIR/test-gate-status (mirrors review-status format)
- Script must be executable (chmod +x)
- Use set -uo pipefail
- Follow header comment pattern from pre-commit-review-gate.sh

The convention-based association (foo.py -> test_foo.py) searches for files matching test_<basename> in the test directory tree. Use 'find' restricted to tests/ directory.

Infrastructure failure handling (fail-open, mirrors pre-commit-review-gate.sh):
- If compute-diff-hash.sh fails or returns empty string -> fail open (exit 0) to avoid blocking on infrastructure issues. Log a warning to stderr. This matches the pattern in pre-commit-review-gate.sh lines 261-265: "Hash computation failed — fail open".

## Acceptance Criteria

- [ ] plugins/dso/hooks/pre-commit-test-gate.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] Hook exits non-zero with MISSING error when test-gate-status is absent for a staged file with associated test
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS.*test_gate_blocked_missing_status'
- [ ] Hook exits non-zero with HASH_MISMATCH error when hash does not match
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS.*test_gate_blocked_hash_mismatch'
- [ ] Hook exits non-zero with NOT_PASSED error when status is not 'passed'
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS.*test_gate_blocked_not_passed'
- [ ] Hook exits 0 for files with no associated test (exempt)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS.*test_gate_passes_no_associated_test'
- [ ] Hook exits 0 when all checks pass (valid status, hash match, passed)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS.*test_gate_passes_valid_status'
- [ ] Hook fails open (exits 0) when compute-diff-hash.sh returns empty string or fails
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS.*test_gate_fails_open_on_hash_error'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

