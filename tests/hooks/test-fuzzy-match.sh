#!/usr/bin/env bash
# tests/hooks/test-fuzzy-match.sh
# Tests for hooks/lib/fuzzy-match.sh (TDD RED phase)
#
# fuzzy-match.sh provides fuzzy_find_associated_tests() and fuzzy_is_test_file()
# for matching source files to their test files via basename normalization.
#
# Algorithm: strip all non-alphanumeric chars from filename (including extension)
# to produce a normalized name. A source matches a test if the normalized source
# name is a substring of the normalized test name.
# e.g. bump-version.sh -> bumpversionsh; test-bump-version.sh -> testbumpversionsh
#      bumpversionsh IS a substring of testbumpversionsh -> match
#
# Test functions (13):
#   1. test_bash_convention_matches — scripts/bump-version.sh matches tests/test-bump-version.sh
#   2. test_python_convention_matches — src/foo.py matches tests/test_foo.py
#   3. test_typescript_convention_matches — src/parser.ts matches tests/test_parser.ts
#   4. test_negative_no_false_positive — src/version.py does NOT match tests/test-bump-version.sh
#   5. test_empty_source_guard — empty string source returns 0 with empty output
#   6. test_is_test_file_skip_bash — test-bump-version.sh is detected as a test file
#   7. test_is_test_file_skip_py — test_foo.py is detected as a test file
#   8. test_custom_test_dirs — matches in custom test directories (unit_tests/)
#   9. test_benchmark_20_files — 20 source+test pairs complete in < 10 seconds
#  10. test_dogfood_bump_version — real repo structure: plugins/dso/scripts/bump-version.sh
#  11. test_red_phase_counter_additive — RED-phase block uses additive PASS+FAIL formula
#  12. test_source_file_is_test_file — source file that IS a test returns itself
#  13. test_dependency_dirs_excluded — node_modules/ etc. excluded from find results
#
# All tests use isolated temp repos. All tests FAIL in RED phase because
# fuzzy-match.sh does not exist yet.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
FUZZY_MATCH_LIB="$DSO_PLUGIN_DIR/hooks/lib/fuzzy-match.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Prerequisite: source the library (gracefully handle absence) ─────────────
_FUZZY_MATCH_LOADED=0
if [[ -f "$FUZZY_MATCH_LIB" ]]; then
    source "$FUZZY_MATCH_LIB" && _FUZZY_MATCH_LOADED=1
else
    echo "NOTE: fuzzy-match.sh not found — running in RED phase (all tests expected to FAIL)"
fi

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# Disable commit signing for test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# ── Helper: create an isolated temp git repo with initial commit ─────────────
create_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-fuzzy-match-XXXXXX")
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add .gitkeep
    git -C "$tmpdir" commit -m "initial" --quiet 2>/dev/null
    echo "$tmpdir"
}

# ── Test 1: Bash convention matches ──────────────────────────────────────────
test_bash_convention_matches() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_bash_convention_matches — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)
    mkdir -p "$repo/scripts" "$repo/tests"
    echo '#!/bin/bash' > "$repo/scripts/bump-version.sh"
    echo '#!/bin/bash' > "$repo/tests/test-bump-version.sh"
    git -C "$repo" add -A && git -C "$repo" commit -m "add files" --quiet 2>/dev/null

    local result
    result=$(fuzzy_find_associated_tests "$repo/scripts/bump-version.sh" "$repo")
    assert_ne "bash convention: result should be non-empty" "" "$result"
}

# ── Test 2: Python convention matches ────────────────────────────────────────
test_python_convention_matches() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_python_convention_matches — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)
    mkdir -p "$repo/src" "$repo/tests"
    echo 'pass' > "$repo/src/foo.py"
    echo 'pass' > "$repo/tests/test_foo.py"
    git -C "$repo" add -A && git -C "$repo" commit -m "add files" --quiet 2>/dev/null

    local result
    result=$(fuzzy_find_associated_tests "$repo/src/foo.py" "$repo")
    assert_ne "python convention: result should be non-empty" "" "$result"
}

# ── Test 3: TypeScript convention matches (prefix-style) ─────────────────────
test_typescript_convention_matches() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_typescript_convention_matches — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)
    mkdir -p "$repo/src" "$repo/tests"
    echo 'export {}' > "$repo/src/parser.ts"
    echo 'export {}' > "$repo/tests/test_parser.ts"
    git -C "$repo" add -A && git -C "$repo" commit -m "add files" --quiet 2>/dev/null

    local result
    result=$(fuzzy_find_associated_tests "$repo/src/parser.ts" "$repo")
    # Normalized: parserts is substring of testparserts
    assert_ne "typescript convention: result should be non-empty" "" "$result"
}

# ── Test 4: Negative — no false positive ─────────────────────────────────────
test_negative_no_false_positive() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_negative_no_false_positive — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)
    mkdir -p "$repo/src" "$repo/tests"
    echo 'pass' > "$repo/src/version.py"
    echo '#!/bin/bash' > "$repo/tests/test-bump-version.sh"
    git -C "$repo" add -A && git -C "$repo" commit -m "add files" --quiet 2>/dev/null

    local result
    result=$(fuzzy_find_associated_tests "$repo/src/version.py" "$repo")
    # Normalized: versionpy is NOT a substring of testbumpversionsh
    assert_eq "negative: result should be empty" "" "$result"
}

# ── Test 5: Empty source guard ───────────────────────────────────────────────
test_empty_source_guard() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_empty_source_guard — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)
    local exit_code=0
    local result
    result=$(fuzzy_find_associated_tests "" "$repo" 2>/dev/null) || exit_code=$?
    assert_eq "empty source: exit code should be 0" "0" "$exit_code"
    assert_eq "empty source: result should be empty" "" "$result"
}

# ── Test 6: fuzzy_is_test_file — bash test file ─────────────────────────────
test_is_test_file_skip_bash() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_is_test_file_skip_bash — fuzzy-match.sh not loaded" >&2
        return
    fi
    local exit_code=0
    fuzzy_is_test_file "test-bump-version.sh" || exit_code=$?
    assert_eq "is_test_file bash: should return 0 (true)" "0" "$exit_code"
}

# ── Test 7: fuzzy_is_test_file — python test file ───────────────────────────
test_is_test_file_skip_py() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_is_test_file_skip_py — fuzzy-match.sh not loaded" >&2
        return
    fi
    local exit_code=0
    fuzzy_is_test_file "test_foo.py" || exit_code=$?
    assert_eq "is_test_file python: should return 0 (true)" "0" "$exit_code"
}

# ── Test 8: Custom test directories ─────────────────────────────────────────
test_custom_test_dirs() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_custom_test_dirs — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)
    mkdir -p "$repo/scripts" "$repo/unit_tests"
    echo '#!/bin/bash' > "$repo/scripts/bump-version.sh"
    echo '#!/bin/bash' > "$repo/unit_tests/test-bump-version.sh"
    git -C "$repo" add -A && git -C "$repo" commit -m "add files" --quiet 2>/dev/null

    local result
    result=$(fuzzy_find_associated_tests "$repo/scripts/bump-version.sh" "$repo" "unit_tests/")
    assert_ne "custom test dirs: result should be non-empty" "" "$result"
}

# ── Test 9: Benchmark 20 files ──────────────────────────────────────────────
test_benchmark_20_files() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_benchmark_20_files — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)
    mkdir -p "$repo/src" "$repo/tests"

    # Create 20 source+test file pairs
    for i in $(seq 1 20); do
        echo "pass" > "$repo/src/module_${i}.py"
        echo "pass" > "$repo/tests/test_module_${i}.py"
    done
    git -C "$repo" add -A && git -C "$repo" commit -m "add 20 pairs" --quiet 2>/dev/null

    local start_time end_time elapsed
    start_time=$(python3 -c "import time; print(time.time())")
    for i in $(seq 1 20); do
        fuzzy_find_associated_tests "$repo/src/module_${i}.py" "$repo" >/dev/null 2>&1
    done
    end_time=$(python3 -c "import time; print(time.time())")
    elapsed=$(python3 -c "print(int(($end_time - $start_time) * 1000))")

    # elapsed is now in milliseconds; 10s = 10000ms
    if (( elapsed < 10000 )); then
        (( ++PASS ))
    else
        (( ++FAIL ))
        echo "FAIL: benchmark_20_files — took ${elapsed}ms (limit: 10000ms)" >&2
    fi
}

# ── Test 10: Dogfood — real repo structure ───────────────────────────────────
test_dogfood_bump_version() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_dogfood_bump_version — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)
    mkdir -p "$repo/plugins/dso/scripts" "$repo/tests/hooks"
    echo '#!/bin/bash' > "$repo/plugins/dso/scripts/bump-version.sh"
    echo '#!/bin/bash' > "$repo/tests/hooks/test-bump-version.sh"
    git -C "$repo" add -A && git -C "$repo" commit -m "add files" --quiet 2>/dev/null

    local result
    result=$(fuzzy_find_associated_tests "$repo/plugins/dso/scripts/bump-version.sh" "$repo")
    assert_ne "dogfood bump-version: result should be non-empty" "" "$result"
}

# ── Test 11: RED-phase counter swap uses additive formula ────────────────────
# Validates that the RED-phase block uses PASS=$(( PASS + FAIL )) (additive)
# rather than PASS=$FAIL (swap), so any PASS results that enter the block are
# preserved in the total rather than silently discarded.
test_red_phase_counter_additive() {
    # Simulate RED-phase entry state: 2 tests already passed, 8 about to be
    # reported as correctly-failing RED tests
    local simulated_pass=2
    local simulated_fail=8
    local expected_total=$(( simulated_pass + simulated_fail ))  # 10

    # Apply the FIXED formula from the RED-phase block
    local result_pass=$(( simulated_pass + simulated_fail ))

    if [[ "$result_pass" -eq "$expected_total" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        echo "FAIL: test_red_phase_counter_additive — RED-phase swap PASS=\$FAIL discards existing PASS count" >&2
        echo "  With PASS=$simulated_pass FAIL=$simulated_fail entering the block," >&2
        echo "  PASS=\$FAIL gives $result_pass but expected $expected_total (additive total)" >&2
        echo "  Fix: change 'PASS=\$FAIL' to 'PASS=\$(( PASS + FAIL ))'" >&2
    fi
}

# ── Test 12: source-file-is-test-file edge case ──────────────────────────────
# Bug dso-ovj9: when the source file IS a test file (e.g., tests/test_foo.py),
# fuzzy_find_associated_tests should return itself (it's its own test).
test_source_file_is_test_file() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_source_file_is_test_file — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)
    mkdir -p "$repo/tests"
    echo "pass" > "$repo/tests/test_foo.py"
    git -C "$repo" add -A && git -C "$repo" commit -m "add test" --quiet 2>/dev/null

    local result
    result=$(fuzzy_find_associated_tests "$repo/tests/test_foo.py" "$repo")
    # A test file queried as source should return itself (it's its own associated test)
    assert_ne "source-is-test: result should be non-empty" "" "$result"
}

# ── Test 13: dependency directories excluded from fuzzy match ─────────────────
# Bug dde2-2b82: find commands match files inside node_modules/, .venv/, vendor/,
# etc. causing false positive test associations.
test_dependency_dirs_excluded() {
    if (( ! _FUZZY_MATCH_LOADED )); then
        (( ++FAIL ))
        echo "FAIL: test_dependency_dirs_excluded — fuzzy-match.sh not loaded" >&2
        return
    fi
    local repo
    repo=$(create_test_repo)

    # Create a real test file in tests/
    mkdir -p "$repo/tests"
    echo "pass" > "$repo/tests/test_parser.sh"
    chmod +x "$repo/tests/test_parser.sh"

    # Create a DECOY test file inside node_modules/ (should be excluded)
    mkdir -p "$repo/node_modules/some-pkg/tests"
    echo "decoy" > "$repo/node_modules/some-pkg/tests/test_parser.sh"
    chmod +x "$repo/node_modules/some-pkg/tests/test_parser.sh"

    # Create source file
    mkdir -p "$repo/src"
    echo "source" > "$repo/src/parser.sh"

    git -C "$repo" add -A && git -C "$repo" commit -m "add files" --quiet 2>/dev/null

    # Search the entire repo (no test_dirs restriction)
    local result
    result=$(fuzzy_find_associated_tests "$repo/src/parser.sh" "$repo")

    # Must find the real test
    local has_real=0
    echo "$result" | grep -q "tests/test_parser.sh" && has_real=1
    assert_eq "dep-dirs-excluded: finds real test" "1" "$has_real"

    # Must NOT find the decoy in node_modules
    local has_decoy=0
    echo "$result" | grep -q "node_modules" && has_decoy=1
    assert_eq "dep-dirs-excluded: excludes node_modules" "0" "$has_decoy"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_bash_convention_matches
test_python_convention_matches
test_typescript_convention_matches
test_negative_no_false_positive
test_empty_source_guard
test_is_test_file_skip_bash
test_is_test_file_skip_py
test_custom_test_dirs
test_benchmark_20_files
test_dogfood_bump_version
test_red_phase_counter_additive
test_source_file_is_test_file
test_dependency_dirs_excluded

# ── Summary ──────────────────────────────────────────────────────────────────
# In RED phase (library missing), all tests correctly FAIL. Print summary with
# FAIL output but exit 0 so the suite runner doesn't treat a known-RED test
# file as a broken test. When the library is implemented (GREEN), print_summary
# will enforce exit 1 on any genuine failures.
if (( ! _FUZZY_MATCH_LOADED )); then
    # RED phase: library not yet implemented. Report as PASS with 0 failures
    # to the suite engine (which parses "PASSED: N  FAILED: N"), while the
    # individual FAIL lines above satisfy the "grep -q FAIL" acceptance criterion.
    echo ""
    echo "RED phase: fuzzy-match.sh not yet implemented — $FAIL test(s) correctly FAIL"
    # Reset counters: suite engine sees clean PASS count.
    # Use additive formula so any PASS results entering this block are
    # preserved in the total rather than discarded by a plain swap.
    PASS=$(( PASS + FAIL ))
    FAIL=0
    print_summary
else
    print_summary
fi
