---
id: dso-fhfi
status: closed
deps: [dso-wqt4, dso-o1u2]
links: []
created: 2026-03-21T16:15:55Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-tpzd
---
# IMPL: Rewrite pre-commit-test-gate.sh to use fuzzy-match.sh for multi-stack test association

Replace the Python-only test association logic in pre-commit-test-gate.sh with calls to fuzzy-match.sh. After this task, the gate triggers for any source file type that has a fuzzy-matched test file.

## TDD Requirement

Tests from task dso-o1u2 (test_gate_bash_script_triggers, test_gate_typescript_triggers, test_gate_test_file_itself_exempt, test_gate_test_dirs_config) must turn GREEN. All 11 original tests must remain GREEN.

## Files

- EDIT: plugins/dso/hooks/pre-commit-test-gate.sh

## Changes

1. After 'source "$HOOK_DIR/lib/deps.sh"', add:
   source "$HOOK_DIR/lib/fuzzy-match.sh"

2. Add config reading after REPO_ROOT determination:
   ```bash
   # Read test directories from config (supports TEST_GATE_TEST_DIRS_OVERRIDE for testing)
   if [[ -n "${TEST_GATE_TEST_DIRS_OVERRIDE:-}" ]]; then
       _TEST_DIRS="$TEST_GATE_TEST_DIRS_OVERRIDE"
   else
       _TEST_DIRS=$(grep '^test_gate\.test_dirs=' "${REPO_ROOT}/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2- || true)
       _TEST_DIRS="${_TEST_DIRS:-tests/}"
   fi
   ```

3. Replace _has_associated_test() entirely:
   ```bash
   _has_associated_test() {
       local src_file="$1"
       # Skip test files themselves using shared fuzzy_is_test_file()
       if fuzzy_is_test_file "$src_file"; then
           return 1
       fi
       local _found
       _found=$(fuzzy_find_associated_tests "$src_file" "$_TEST_DIRS" "${REPO_ROOT:-.}" | head -1 || true)
       [[ -n "$_found" ]]
   }
   ```

4. Replace _get_associated_test_path() entirely:
   ```bash
   _get_associated_test_path() {
       local src_file="$1"
       if fuzzy_is_test_file "$src_file"; then
           return
       fi
       fuzzy_find_associated_tests "$src_file" "$_TEST_DIRS" "${REPO_ROOT:-.}" | head -1 || true
   }
   ```

5. Update the DESIGN block comment to describe new algorithm:
   - Change 'convention-based' to 'fuzzy-match-based'
   - Describe alphanum normalization
   - Reference fuzzy-match.sh

6. Preserve all existing behavior: NEEDS_TEST_GATE loop, exemption check, status file checks, hash check all remain unchanged.

## Backward Compatibility

The Python test_foo.py convention still works: foo.py normalizes to foopy, test_foo.py normalizes to testfoopy, testfoopy contains foopy. All 11 existing tests continue to pass because they use Python conventions which are a subset of fuzzy matching.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] fuzzy-match.sh sourced in pre-commit-test-gate.sh
  Verify: grep -q 'fuzzy-match.sh' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] Python-only .py guard removed from _has_associated_test
  Verify: ! grep -qE '_has_associated_test.*\.py|src_file.*\*\.py' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] fuzzy_is_test_file called in gate
  Verify: grep -q 'fuzzy_is_test_file' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] fuzzy_find_associated_tests called in gate
  Verify: grep -q 'fuzzy_find_associated_tests' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] TEST_GATE_TEST_DIRS_OVERRIDE env var supported
  Verify: grep -q 'TEST_GATE_TEST_DIRS_OVERRIDE' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] All 11 original tests remain GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS:.*test_gate_blocked_missing_status'
- [ ] test_gate_bash_script_triggers passes GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS:.*test_gate_bash_script_triggers'
- [ ] test_gate_test_file_itself_exempt passes GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS:.*test_gate_test_file_itself_exempt'
- [ ] test_gate_test_dirs_config passes GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -q 'PASS:.*test_gate_test_dirs_config'


## Notes

**2026-03-21T17:47:58Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T17:48:07Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T17:48:24Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓

**2026-03-21T17:49:41Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T17:49:41Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T17:49:59Z**

CHECKPOINT 6/6: Done ✓
