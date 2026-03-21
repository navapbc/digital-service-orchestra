---
id: dso-wqt4
status: closed
deps: [dso-ydzw]
links: []
created: 2026-03-21T16:15:14Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-tpzd
---
# IMPL: Create plugins/dso/hooks/lib/fuzzy-match.sh shared fuzzy match library

Implement the fuzzy-match.sh shared library that provides tech-stack-agnostic test file association. This is the core algorithmic change that enables the gate to work across all file types.

## TDD Requirement

The failing tests from task dso-ydzw drive this implementation. All tests in tests/hooks/test-fuzzy-match.sh must turn GREEN after this task.

## Files

- CREATE: plugins/dso/hooks/lib/fuzzy-match.sh

## Implementation

Implement three public bash functions with a load-once guard:

```bash
[[ "${_FUZZY_MATCH_LOADED:-}" == "1" ]] && return 0
_FUZZY_MATCH_LOADED=1

fuzzy_normalize() {
    local input="$1"
    # Strip all non-alphanumeric characters, lowercase
    echo "$input" | tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]'
}

fuzzy_is_test_file() {
    local filename="$1"
    local base
    base=$(basename "$filename")
    # Handles: test_*.py, test-*.sh, *.test.ts, *.spec.ts, *.test.js, *.spec.js, *_test.go, test-*.*, test_*.*
    [[ "$base" == test_* ]] || [[ "$base" == test-* ]] ||     [[ "$base" == *.test.* ]] || [[ "$base" == *.spec.* ]] ||     [[ "$base" == *_test.* ]]
}

fuzzy_find_associated_tests() {
    local src_file="$1"
    local test_dirs="$2"   # colon or space separated
    local repo_root="$3"
    
    local norm_src
    norm_src=$(fuzzy_normalize "$(basename "$src_file")")
    
    # Safety guard: empty normalized source returns nothing
    [[ -z "$norm_src" ]] && return 0
    
    # Split test_dirs on colon or space
    local IFS=': '
    local dir
    for dir in $test_dirs; do
        [[ -z "$dir" ]] && continue
        local search_path="${repo_root}/${dir}"
        [[ -d "$search_path" ]] || continue
        while IFS= read -r test_file; do
            [[ -z "$test_file" ]] && continue
            local norm_test
            norm_test=$(fuzzy_normalize "$(basename "$test_file")")
            if [[ "$norm_test" == *"$norm_src"* ]] && [[ "$norm_test" == *"test"* ]]; then
                echo "${test_file#"$repo_root/"}"
            fi
        done < <(find "$search_path" -type f 2>/dev/null)
    done
}
```

## Notes

- Load-once guard prevents double-sourcing when multiple hooks source this library
- fuzzy_normalize strips ALL non-alphanumeric chars including extension separator (so bump-version.sh -> bumpversionsh)
- fuzzy_is_test_file detects test files by naming convention to prevent circular self-association
- fuzzy_find_associated_tests uses find + substring match (no grep, portable)
- IFS splitting handles both colon-separated and space-separated test_dirs input

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] plugins/dso/hooks/lib/fuzzy-match.sh exists and is non-empty
  Verify: test -s $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/fuzzy-match.sh
- [ ] fuzzy_find_associated_tests function defined
  Verify: grep -q 'fuzzy_find_associated_tests' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/fuzzy-match.sh
- [ ] fuzzy_is_test_file function defined
  Verify: grep -q 'fuzzy_is_test_file' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/fuzzy-match.sh
- [ ] fuzzy_normalize function defined
  Verify: grep -q 'fuzzy_normalize' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/fuzzy-match.sh
- [ ] Load-once guard present
  Verify: grep -q '_FUZZY_MATCH_LOADED' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/fuzzy-match.sh
- [ ] test_bash_convention_matches passes GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh 2>&1 | grep -q 'PASS:.*test_bash_convention_matches'
- [ ] test_python_convention_matches passes GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh 2>&1 | grep -q 'PASS:.*test_python_convention_matches'
- [ ] test_benchmark_20_files passes (20 files < 10s)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh 2>&1 | grep -q 'PASS:.*test_benchmark_20_files'
- [ ] test_dogfood_bump_version passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh 2>&1 | grep -q 'PASS:.*test_dogfood_bump_version'
- [ ] test_negative_no_false_positive passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh 2>&1 | grep -q 'PASS:.*test_negative_no_false_positive'
- [ ] test_empty_source_guard passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-fuzzy-match.sh 2>&1 | grep -q 'PASS:.*test_empty_source_guard'


**2026-03-21T16:58:02Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T16:58:15Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T16:58:21Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓

**2026-03-21T16:58:44Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T16:59:45Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T17:09:55Z**

CHECKPOINT 6/6: Done ✓
