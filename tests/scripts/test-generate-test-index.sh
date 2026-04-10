#!/usr/bin/env bash
# tests/scripts/test-generate-test-index.sh
# TDD RED tests for plugins/dso/scripts/generate-test-index.sh
#
# Covers:
#   - Scanner finds tests that fuzzy match misses → writes to .test-index
#   - Scanner skips source files that fuzzy match already covers
#   - Scanner skips source files with no test anywhere
#   - Coverage summary output
#   - Idempotent runs (no duplicate entries)
#   - Stale entry replacement
#   - Missing test_dirs → exit 0 with warning
#   - Output format valid for parse_test_index()
#   - Broader scan finds tests outside configured dirs
#
# Usage: bash tests/scripts/test-generate-test-index.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCANNER="$DSO_PLUGIN_DIR/scripts/generate-test-index.sh"
FUZZY_MATCH_LIB="$DSO_PLUGIN_DIR/hooks/lib/fuzzy-match.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-generate-test-index.sh ==="

# ── RED guard ──────────────────────────────────────────────────────────────────
# If the scanner script doesn't exist yet, skip all tests gracefully.
_red_guard() {
    if [[ ! -f "$SCANNER" ]]; then
        echo "SKIP: $1 (generate-test-index.sh not yet implemented)"
        return 1
    fi
    return 0
}

# Create a shared top-level temp dir; cleaned up on exit
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# ── Helper: set up a minimal fake repo ─────────────────────────────────────────
# Creates: repo_root with src file(s) and optionally test file(s)
# Usage: setup_repo <name>
#   Sets REPO variable to the created repo root
setup_repo() {
    local name="$1"
    REPO="$TMPDIR_FIXTURE/$name"
    mkdir -p "$REPO"
}

# ── Helper: create a file (parents auto-created) ──────────────────────────────
create_file() {
    local filepath="$1"
    local content="${2:-# placeholder}"
    mkdir -p "$(dirname "$filepath")"
    printf '%s\n' "$content" > "$filepath"
}

# ─────────────────────────────────────────────────────────────────────────────
# TEST 1: test_scanner_finds_test_missing_from_fuzzy_match
# Given a source file whose test exists on disk but is NOT found by
# fuzzy_find_associated_tests, assert scanner writes an entry to .test-index
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_finds_test_missing_from_fuzzy_match"; then
    setup_repo "finds_missing"
    # Source file
    create_file "$REPO/src/utils/data_processor.py" "def process(): pass"
    # Test file with a name that fuzzy match won't associate
    # (fuzzy match needs normalized source as substring of normalized test name)
    # Use a completely different naming convention that fuzzy won't find
    create_file "$REPO/tests/integration/test_data_pipeline_processor_suite.py" "def test_it(): pass"

    # Verify fuzzy match does NOT find this association
    source "$FUZZY_MATCH_LIB"
    _FUZZY_MATCH_LOADED=  # force reload if needed
    source "$FUZZY_MATCH_LIB"
    fuzzy_result=$(fuzzy_find_associated_tests "$REPO/src/utils/data_processor.py" "$REPO" "tests")
    # If fuzzy DOES find it, this test premise is invalid — but we assert scanner behavior anyway
    # The scanner should find the test via broader scan and write it to .test-index

    # Run scanner
    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null

    # Assert .test-index was created and contains the source file
    assert_eq "test_scanner_finds_test_missing: .test-index exists" "0" "$(test -f "$REPO/.test-index" && echo 0 || echo 1)"
    index_content=$(cat "$REPO/.test-index" 2>/dev/null || true)
    assert_contains "test_scanner_finds_test_missing: has source entry" "src/utils/data_processor.py" "$index_content"
fi
assert_pass_if_clean "test_scanner_finds_test_missing_from_fuzzy_match"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 2: test_scanner_skips_source_with_fuzzy_match
# Given a source file whose test IS found by fuzzy_find_associated_tests,
# assert scanner does NOT add an entry to .test-index
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_skips_source_with_fuzzy_match"; then
    setup_repo "skips_fuzzy"
    # Source file and a test that fuzzy match WILL find (normalized source is substring of test)
    create_file "$REPO/src/calculator.py" "def add(): pass"
    create_file "$REPO/tests/test_calculator.py" "def test_add(): pass"

    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null

    # .test-index may or may not exist, but it should NOT contain calculator.py
    if [[ -f "$REPO/.test-index" ]]; then
        index_content=$(cat "$REPO/.test-index")
        # Filter out comments and blank lines, check for source entry
        has_entry=$(grep -v '^#' "$REPO/.test-index" | grep -v '^$' | grep -c "src/calculator.py" || true)
        assert_eq "test_scanner_skips_source_with_fuzzy_match: no entry" "0" "$has_entry"
    else
        # No index file means nothing was written — correct behavior
        assert_eq "test_scanner_skips_source_with_fuzzy_match: no index" "0" "0"
    fi
fi
assert_pass_if_clean "test_scanner_skips_source_with_fuzzy_match"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 3: test_scanner_skips_source_with_no_test
# Given a source file with no test anywhere, assert scanner does NOT
# add an entry to .test-index
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_skips_source_with_no_test"; then
    setup_repo "skips_no_test"
    create_file "$REPO/src/orphan_module.py" "def orphan(): pass"
    # No test files at all

    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null

    if [[ -f "$REPO/.test-index" ]]; then
        has_entry=$(grep -v '^#' "$REPO/.test-index" | grep -v '^$' | grep -c "orphan_module.py" || true)
        assert_eq "test_scanner_skips_source_with_no_test: no entry" "0" "$has_entry"
    else
        assert_eq "test_scanner_skips_source_with_no_test: no index" "0" "0"
    fi
fi
assert_pass_if_clean "test_scanner_skips_source_with_no_test"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 4: test_scanner_coverage_summary_output
# Assert stdout includes a coverage summary with counts for fuzzy matches,
# index entries, and no-coverage files
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_coverage_summary_output"; then
    setup_repo "coverage_summary"
    create_file "$REPO/src/matched.py" "pass"
    create_file "$REPO/tests/test_matched.py" "pass"
    create_file "$REPO/src/indexed.py" "pass"
    create_file "$REPO/tests/integration/test_indexed_e2e.py" "pass"
    create_file "$REPO/src/uncovered.py" "pass"

    output=$(bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>&1)

    # Summary should mention fuzzy/index/no-coverage counts
    assert_contains "test_scanner_coverage_summary: has fuzzy count" "fuzzy" "$output"
    assert_contains "test_scanner_coverage_summary: has index count" "index" "$output"
    assert_contains "test_scanner_coverage_summary: has no-coverage count" "no-coverage" "$output"
fi
assert_pass_if_clean "test_scanner_coverage_summary_output"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 5: test_scanner_idempotent
# Running scanner twice on the same repo produces the same .test-index
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_idempotent"; then
    setup_repo "idempotent"
    create_file "$REPO/src/utils/data_processor.py" "def process(): pass"
    create_file "$REPO/tests/integration/test_data_pipeline_processor_suite.py" "def test_it(): pass"

    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null
    first_run=$(cat "$REPO/.test-index" 2>/dev/null || true)

    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null
    second_run=$(cat "$REPO/.test-index" 2>/dev/null || true)

    assert_eq "test_scanner_idempotent: same output" "$first_run" "$second_run"
fi
assert_pass_if_clean "test_scanner_idempotent"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 6: test_scanner_overwrites_existing_stale_entries
# Running scanner on a repo where .test-index already has stale entries
# replaces them correctly
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_overwrites_existing_stale_entries"; then
    setup_repo "stale_entries"
    # Pre-populate .test-index with a stale entry
    create_file "$REPO/.test-index" "src/old_file.py: tests/test_old_file.py"
    # Only source file present now is a new one
    create_file "$REPO/src/new_module.py" "pass"
    create_file "$REPO/tests/integration/test_new_module_suite.py" "pass"

    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null

    index_content=$(cat "$REPO/.test-index" 2>/dev/null || true)
    # Stale entry should be gone
    stale_count=$(echo "$index_content" | grep -c "old_file.py" || true)
    assert_eq "test_scanner_overwrites_stale: old entry removed" "0" "$stale_count"
fi
assert_pass_if_clean "test_scanner_overwrites_existing_stale_entries"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 7: test_scanner_handles_missing_test_dirs
# If configured test_dirs directory does not exist, scanner exits 0 with warning
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_handles_missing_test_dirs"; then
    setup_repo "missing_dirs"
    create_file "$REPO/src/something.py" "pass"
    # Do NOT create tests/ directory

    rc=0
    output=$(bash "$SCANNER" --repo-root "$REPO" --test-dirs "nonexistent_dir" 2>&1) || rc=$?

    assert_eq "test_scanner_handles_missing_test_dirs: exit 0" "0" "$rc"
    # Should emit a warning about missing directory
    assert_contains "test_scanner_handles_missing_test_dirs: warning" "warn" "$(echo "$output" | tr '[:upper:]' '[:lower:]')"
fi
assert_pass_if_clean "test_scanner_handles_missing_test_dirs"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 8: test_scanner_output_format_valid
# Generated .test-index entries match format 'source/path.ext: test/path1.ext'
# parseable by parse_test_index() from pre-commit-test-gate.sh
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_output_format_valid"; then
    setup_repo "format_valid"
    create_file "$REPO/src/utils/data_processor.py" "def process(): pass"
    create_file "$REPO/tests/integration/test_data_pipeline_processor_suite.py" "def test_it(): pass"

    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null

    # Read non-comment, non-blank lines from .test-index
    valid_format=true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Must match: <path>: <path> (with optional comma-separated additional paths)
        # Format: source_path: test_path1[, test_path2...]
        if ! [[ "$line" =~ ^[^:]+:[[:space:]]+[^[:space:]]+ ]]; then
            valid_format=false
            break
        fi
    done < "$REPO/.test-index"

    assert_eq "test_scanner_output_format_valid: all lines valid" "true" "$valid_format"

    # Verify parse_test_index can actually read it
    # Source the test gate to get parse_test_index
    REPO_ROOT="$REPO"
    export REPO_ROOT
    # parse_test_index looks for $REPO_ROOT/.test-index
    source "$DSO_PLUGIN_DIR/hooks/lib/fuzzy-match.sh"
    # We need to test parse_test_index from pre-commit-test-gate.sh
    # Extract just the function (it reads from $REPO_ROOT/.test-index)
    parsed=$(
        REPO_ROOT="$REPO" \
        bash -c "
            REPO_ROOT='$REPO'
            $(sed -n '/^parse_test_index()/,/^}/p' "$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh")
            parse_test_index 'src/utils/data_processor.py'
        "
    )
    assert_ne "test_scanner_output_format_valid: parse returns result" "" "$parsed"
fi
assert_pass_if_clean "test_scanner_output_format_valid"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 9: test_scanner_broader_scan_finds_tests_outside_configured_dirs
# Given a source file with a test in a non-configured test dir,
# fuzzy_find_associated_tests returns nothing but the broader filesystem
# scan finds the test — scanner writes it as an INDEX CANDIDATE to .test-index
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_broader_scan_finds_tests_outside_configured_dirs"; then
    setup_repo "broader_scan"
    create_file "$REPO/src/widget.py" "pass"
    # Test lives outside the configured test_dirs (e.g., in a sibling "specs/" dir)
    create_file "$REPO/specs/test_widget.py" "pass"
    # Configure test_dirs to only look in "tests/" (which doesn't contain the test)
    mkdir -p "$REPO/tests"

    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null

    index_content=$(cat "$REPO/.test-index" 2>/dev/null || true)
    # Scanner should find the test via broader scan and write an INDEX CANDIDATE
    assert_contains "test_scanner_broader_scan: has widget entry" "widget.py" "$index_content"
    assert_contains "test_scanner_broader_scan: has specs path" "specs/" "$index_content"
fi
assert_pass_if_clean "test_scanner_broader_scan_finds_tests_outside_configured_dirs"

# ─────────────────────────────────────────────────────────────────────────────
# Test: scanner excludes dependency directories from broader scan
# Bug dde2-2b82: find commands should skip node_modules/, .venv/, vendor/, etc.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_excludes_dependency_dirs"; then
    setup_repo "dep_exclusion"
    create_file "$REPO/src/parser.py" "pass"
    # Real test file in an unusual location (found by broader scan)
    create_file "$REPO/extra/test_parser.py" "pass"
    # Decoy test file inside node_modules (should be excluded)
    create_file "$REPO/node_modules/pkg/test_parser.py" "decoy"
    mkdir -p "$REPO/tests"

    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null

    index_content=$(cat "$REPO/.test-index" 2>/dev/null || true)
    # Scanner should find the real test via broader scan
    assert_contains "test_scanner_excludes_dep_dirs: has parser entry" "parser.py" "$index_content"
    # Scanner must NOT include node_modules paths
    has_node_modules=0
    _tmp="$index_content"; [[ "$_tmp" == *"node_modules"* ]] && has_node_modules=1
    assert_eq "test_scanner_excludes_dep_dirs: no node_modules in index" "0" "$has_node_modules"
fi
assert_pass_if_clean "test_scanner_excludes_dependency_dirs"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
# TEST: test_scanner_broader_scan_finds_multiple_source_files_consistently
# When multiple source files each have a test discovered only via broader scan,
# the scanner must write ALL of them to .test-index in a single run.
# This verifies the cached find approach (w20-gm71) does not scope or exhaust
# the file list after the first source file processes it.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
if _red_guard "test_scanner_broader_scan_finds_multiple_source_files_consistently"; then
    setup_repo "multi_source_cache"
    # Three source files
    create_file "$REPO/src/alpha.py" "pass"
    create_file "$REPO/src/beta.py" "pass"
    create_file "$REPO/src/gamma.py" "pass"
    # Corresponding tests in a non-configured dir (broader scan only)
    create_file "$REPO/specs/test_alpha.py" "pass"
    create_file "$REPO/specs/test_beta.py" "pass"
    create_file "$REPO/specs/test_gamma.py" "pass"
    mkdir -p "$REPO/tests"

    bash "$SCANNER" --repo-root "$REPO" --test-dirs "tests" 2>/dev/null

    index_content=$(cat "$REPO/.test-index" 2>/dev/null || true)
    assert_contains "test_scanner_multi_cache: alpha found" "alpha.py" "$index_content"
    assert_contains "test_scanner_multi_cache: beta found" "beta.py" "$index_content"
    assert_contains "test_scanner_multi_cache: gamma found" "gamma.py" "$index_content"
fi
assert_pass_if_clean "test_scanner_broader_scan_finds_multiple_source_files_consistently"

# ─────────────────────────────────────────────────────────────────────────────
print_summary
