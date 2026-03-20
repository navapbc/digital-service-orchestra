---
id: w21-vyio
status: in_progress
deps: [w21-4dnw]
links: []
created: 2026-03-20T22:02:27Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-8jaf
---
# IMPL: Add exemption support to pre-commit-test-gate.sh

Modify plugins/dso/hooks/pre-commit-test-gate.sh to respect test exemptions recorded by record-test-exemption.sh.

CHANGE SUMMARY:
After discovering staged files that need the test gate (NEEDS_TEST_GATE=true), and BEFORE checking for test-gate-status, add an exemption check:

1. Load the exemptions file from $ARTIFACTS_DIR/test-exemptions (if it exists)
2. For each staged source file requiring the gate:
   a. Find its associated test file(s) (same convention as existing _has_associated_test logic)
   b. Check if ALL associated tests are in the exemptions file
   c. If ALL associated tests are exempted: skip the test-gate-status check for that file (treat as passing)
3. If after exemption filtering NO files remain that require the gate: exit 0
4. Otherwise: proceed with the existing test-gate-status check as normal

EXEMPTION FILE FORMAT (matches record-test-exemption.sh):
  Path: $ARTIFACTS_DIR/test-exemptions
  One entry per line: node_id=<test-file-path>|threshold=60|timestamp=<ISO8601>
  Parsing: grep for the test file path in the node_id field (single-parsing-path)

HELPER FUNCTION to add:
  _is_test_exempted() — accepts test file path, returns 0 if exempted, 1 if not
  Reads the exemptions file and checks for a line where node_id=<test-file-path>

DESIGN NOTES:
- The exemption check must come BEFORE the test-gate-status check so that a missing
  test-gate-status file does not block a commit where all tests are exempted
- An exemption is file-path-based (test_foo.sh path), not pytest node_id, because
  the gate discovers tests by file path via convention
- If the exemptions file does not exist: no tests are exempted (non-blocking)
- Existing behavior is unchanged for non-exempted files

ENVIRONMENT:
  TEST_EXEMPTIONS_OVERRIDE — override path to exemptions file (for testing, parallel to COMPUTE_DIFF_HASH_OVERRIDE)

TDD Requirement: Run bash tests/hooks/test-pre-commit-test-gate.sh FIRST — the 3 new exemption test cases (tests 9-11) must FAIL before this change. After implementation, all tests including the new ones must PASS.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Gate exits 0 when all associated tests for a staged file are exempted (even without test-gate-status)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS.*test_gate_passes_no_status_but_fully_exempted'
- [ ] Gate exits non-zero when test is NOT exempted and test-gate-status is missing
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS.*test_gate_blocked_when_test_not_exempted'
- [ ] Exemption with status present still passes gate
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS.*test_gate_passes_when_test_exempted'
- [ ] All 11 test cases in test-pre-commit-test-gate.sh pass
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh
- [ ] Existing gate behavior unchanged for non-exempted files (all 8 original tests still pass)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -c '^PASS:' | awk '{exit ($1 < 11)}'
- [ ] TEST_EXEMPTIONS_OVERRIDE env var supported for test injection
  Verify: grep -q 'TEST_EXEMPTIONS_OVERRIDE' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] Gate treats absent or malformed test-exemptions file as no exemptions (fail-safe, consistent with fail-open pattern)
  Verify: grep -q 'test-exemptions' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh && grep -q '\-f.*exemption\|exemptions.*exists\|-f.*test-exempt' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh

## Notes

**2026-03-20T23:07:25Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T23:07:40Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T23:08:00Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓ — tests 9-11 pass vacuously via RED guard; will fail once 'test-exemptions' string is present without logic

**2026-03-20T23:09:07Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T23:09:07Z**

CHECKPOINT 5/6: All 11 tests pass ✓

**2026-03-20T23:21:10Z**

CHECKPOINT 6/6: Done ✓ — All 11 test-pre-commit-test-gate tests pass, all 1033 hook tests pass, ruff checks pass, all AC verified
