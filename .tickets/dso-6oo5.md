---
id: dso-6oo5
status: open
deps: [dso-wqt4, dso-a6nl]
links: []
created: 2026-03-21T16:16:24Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-tpzd
---
# IMPL: Update record-test-status.sh to use fuzzy-match.sh for test discovery

Replace the hardcoded Python-only test discovery loop in record-test-status.sh (lines 83-117) with calls to fuzzy_find_associated_tests() from the shared fuzzy-match.sh library.

## TDD Requirement

Tests from task dso-a6nl (test_record_bash_script_discovers_test, test_record_uses_configured_test_dirs) must turn GREEN. All existing record-test-status tests must remain GREEN.

## Files

- EDIT: plugins/dso/hooks/record-test-status.sh

## Changes

1. After 'source "$HOOK_DIR/lib/deps.sh"', add:
   source "$HOOK_DIR/lib/fuzzy-match.sh"

2. After REPO_ROOT determination, add config reading (same pattern as Task 4):
   ```bash
   if [[ -n "${TEST_GATE_TEST_DIRS_OVERRIDE:-}" ]]; then
       _TEST_DIRS="$TEST_GATE_TEST_DIRS_OVERRIDE"
   else
       _TEST_DIRS=$(grep '^test_gate\.test_dirs=' "${REPO_ROOT}/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2- || true)
       _TEST_DIRS="${_TEST_DIRS:-tests/}"
   fi
   ```

3. Replace the test discovery loop (lines 85-117, the while loop with basename/test_pattern/find):
   ```bash
   # Discover associated test files using fuzzy matching
   ASSOCIATED_TESTS=()
   while IFS= read -r src_file; do
       [[ -z "$src_file" ]] && continue
       
       # Skip if src_file is itself a test file
       if fuzzy_is_test_file "$src_file"; then
           continue
       fi
       
       while IFS= read -r test_file; do
           [[ -z "$test_file" ]] && continue
           full_test_path="$REPO_ROOT/$test_file"
           
           if [[ ! -f "$full_test_path" ]]; then
               echo "WARNING: skipping non-regular file: $test_file" >&2
               continue
           fi
           
           if [[ "$test_file" == *.sh ]] && [[ ! -x "$full_test_path" ]]; then
               echo "WARNING: skipping non-executable shell test: $test_file" >&2
               continue
           fi
           
           ASSOCIATED_TESTS+=("$test_file")
       done < <(fuzzy_find_associated_tests "$src_file" "$_TEST_DIRS" "$REPO_ROOT")
       
   done <<< "$STAGED_FILES"
   ```

4. Remove lines 88-94 (basename/name_no_ext/test_pattern variables) and lines 96-115 (old find loop with test_pattern).

5. Keep all downstream logic (deduplication, no-test exit, diff hash, test runner dispatch) unchanged.

## Backward Compatibility

Python test_foo.py is still discovered (foopy is substring of testfoopy, both containing 'test').

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] fuzzy-match.sh sourced in record-test-status.sh
  Verify: grep -q 'fuzzy-match.sh' $(git rev-parse --show-toplevel)/plugins/dso/hooks/record-test-status.sh
- [ ] Hardcoded test_pattern variable removed from discovery section
  Verify: ! grep -q 'test_pattern.*test_' $(git rev-parse --show-toplevel)/plugins/dso/hooks/record-test-status.sh
- [ ] fuzzy_find_associated_tests called in recorder
  Verify: grep -q 'fuzzy_find_associated_tests' $(git rev-parse --show-toplevel)/plugins/dso/hooks/record-test-status.sh
- [ ] TEST_GATE_TEST_DIRS_OVERRIDE env var supported
  Verify: grep -q 'TEST_GATE_TEST_DIRS_OVERRIDE' $(git rev-parse --show-toplevel)/plugins/dso/hooks/record-test-status.sh
- [ ] test_record_bash_script_discovers_test passes GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep -q 'PASS:.*test_record_bash_script_discovers_test'
- [ ] test_record_uses_configured_test_dirs passes GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh 2>&1 | grep -q 'PASS:.*test_record_uses_configured_test_dirs'

