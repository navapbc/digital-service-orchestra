---
id: w21-hcj4
status: closed
deps: []
links: []
created: 2026-03-20T22:01:18Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-8jaf
---
# RED: Write failing tests for record-test-exemption.sh

Write failing tests for hooks/record-test-exemption.sh BEFORE the script exists (TDD RED phase).

Create tests/hooks/test-record-test-exemption.sh with the following test cases:

1. test_exemption_written_on_timeout — record-test-exemption.sh exits 0 AND writes an exemption entry with node_id, threshold=60, and timestamp to the exemptions file when the test runner times out (mock runner exits 124)
2. test_no_exemption_on_passing_test — when the test completes within 60s (exit 0), record-test-exemption.sh does NOT write an exemption and exits non-zero (error: test did not timeout)
3. test_exemption_file_format — the written exemption entry contains node_id=<test>, threshold=60, and timestamp=<ISO8601> fields parseable by the gate
4. test_missing_node_id_argument — calling record-test-exemption.sh with no argument exits non-zero with a usage error
5. test_exemption_idempotent — running record-test-exemption.sh twice for the same node_id results in exactly one entry for that node_id in the exemptions file (idempotent overwrite, not duplicate append)

Use isolated temp directories for all file I/O (WORKFLOW_PLUGIN_ARTIFACTS_DIR override).
Use RECORD_TEST_EXEMPTION_RUNNER env var to inject mock test runners (mirrors RECORD_TEST_STATUS_RUNNER pattern).
Script under test: $DSO_PLUGIN_DIR/hooks/record-test-exemption.sh

RED-phase guard: if script does not exist, print NOTE and pass trivially:
  if [[ ! -f "$EXEMPTION_SCRIPT" ]]; then
    echo "NOTE: record-test-exemption.sh not found — running in RED phase"
    <assert trivially for each test>
  fi

Source $PLUGIN_ROOT/tests/lib/assert.sh for assert_eq, assert_ne, assert_contains, print_summary.

TDD Requirement: bash tests/hooks/test-record-test-exemption.sh must be runnable (exits 0 in RED phase via guard).

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/hooks/test-record-test-exemption.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-exemption.sh
- [ ] Test file contains all 5 required test functions
  Verify: grep -c 'test_exemption_written_on_timeout\|test_no_exemption_on_passing\|test_exemption_file_format\|test_missing_node_id\|test_exemption_idempotent' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-exemption.sh | awk '{exit ($1 < 5)}'
- [ ] Test file sources tests/lib/assert.sh
  Verify: grep -q 'assert.sh' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-exemption.sh
- [ ] RED-phase guard pattern present (handles missing script gracefully)
  Verify: grep -q 'not found\|RED phase' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-exemption.sh
- [ ] RECORD_TEST_EXEMPTION_RUNNER env var used for mock runner injection
  Verify: grep -q 'RECORD_TEST_EXEMPTION_RUNNER' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-exemption.sh

## Notes

**2026-03-20T22:07:59Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T22:08:08Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T22:09:06Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T22:09:15Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED phase — no implementation needed)

**2026-03-20T22:13:00Z**

CHECKPOINT 5/6: Tests run — PASSED: 5 FAILED: 0 in RED phase; run-all.sh Overall: PASS ✓

**2026-03-20T22:13:15Z**

CHECKPOINT 6/6: Done ✓ — all AC verified: executable, 5 test functions, assert.sh sourced, RED-phase guard, RECORD_TEST_EXEMPTION_RUNNER
