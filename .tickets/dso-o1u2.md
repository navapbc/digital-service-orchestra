---
id: dso-o1u2
status: closed
deps: [dso-wqt4]
links: []
created: 2026-03-21T16:15:35Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-tpzd
---
# RED: Extend test-pre-commit-test-gate.sh with multi-stack fuzzy match tests

Add new test cases to tests/hooks/test-pre-commit-test-gate.sh that verify the gate triggers for non-Python source files. These tests must FAIL against the current Python-only gate. After Task 4 (gate rewrite), they must pass GREEN.

## TDD Requirement

New test functions must FAIL against current pre-commit-test-gate.sh. The current gate only handles .py files — staging a .sh file will cause the gate to exit 0 (no associated test found) rather than exit 1 (blocked). After Task 4, the gate uses fuzzy matching and these tests pass.

## Files

- EDIT: tests/hooks/test-pre-commit-test-gate.sh (add new test functions before print_summary)

## New Test Functions to Add

1. test_gate_bash_script_triggers:
   - Create isolated git repo
   - Create scripts/bump-version.sh (source) + tests/test-bump-version.sh (test file, must exist on disk)
   - Stage bump-version.sh (only the source, not the test file)
   - Run gate WITHOUT test-gate-status file
   - Assert exit != 0 (gate should block because bash script has associated test)
   - RED: Current gate exits 0 (no .py file found, passes through)

2. test_gate_typescript_triggers:
   - Create isolated git repo
   - Create src/parser.ts (source) + tests/test_parser.ts (test file — prefix style: test_parser.ts normalized testparserts contains parserts which is normalized parser.ts)
   - Stage parser.ts
   - Run gate WITHOUT test-gate-status
   - Assert exit != 0 (blocked)
   - RED: Current gate exits 0

3. test_gate_test_file_itself_exempt:
   - Create isolated git repo
   - Create tests/test-bump-version.sh (this IS a test file)
   - Stage tests/test-bump-version.sh
   - Run gate (no status needed)
   - Assert exit == 0 (test files are NOT sources, must not trigger gate on themselves)
   - RED: With the new fuzzy logic, test-bump-version.sh would match itself unless fuzzy_is_test_file() skips it

4. test_gate_test_dirs_config:
   - Create isolated git repo
   - Create scripts/bump-version.sh + unit_tests/test-bump-version.sh (NOT in tests/)
   - Stage bump-version.sh
   - Run gate WITH TEST_GATE_TEST_DIRS_OVERRIDE=unit_tests/
   - Assert exit != 0 (gate finds test in unit_tests/, blocks without status)
   - RED: Current gate doesn't support configurable test dirs

Add these to the run_test invocations at the bottom of the file, before print_summary.

## Note on test infrastructure
The test uses TEST_GATE_TEST_DIRS_OVERRIDE env var (to be supported by Task 4). In the RED phase, the gate ignores this env var, so test_gate_test_dirs_config will still fail (gate won't find tests in unit_tests/).

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] test_gate_bash_script_triggers function added to test-pre-commit-test-gate.sh
  Verify: grep -q 'test_gate_bash_script_triggers' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] test_gate_typescript_triggers function added
  Verify: grep -q 'test_gate_typescript_triggers' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] test_gate_test_file_itself_exempt function added
  Verify: grep -q 'test_gate_test_file_itself_exempt' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] test_gate_test_dirs_config function added
  Verify: grep -q 'test_gate_test_dirs_config' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] New tests fail (RED) against current gate before Task 4 implementation
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'FAIL:.*test_gate_bash_script_triggers'


## Notes

<!-- note-id: zyub653u -->
<!-- timestamp: 2026-03-21T17:32:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: zd8aoiqp -->
<!-- timestamp: 2026-03-21T17:32:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: zmmsjnhm -->
<!-- timestamp: 2026-03-21T17:33:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: rjlj99t8 -->
<!-- timestamp: 2026-03-21T17:33:53Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete (RED task) ✓

<!-- note-id: 7sm90ssj -->
<!-- timestamp: 2026-03-21T17:44:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — 11 existing tests PASS, 3 new RED tests FAIL as expected (bash_script, typescript, test_dirs_config). test_file_itself_exempt PASSES (gate exits 0 for non-.py for wrong reason; will pass for right reason after Task 4). test-doc-migration.sh failure is pre-existing.

<!-- note-id: gdih8he7 -->
<!-- timestamp: 2026-03-21T17:44:47Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
