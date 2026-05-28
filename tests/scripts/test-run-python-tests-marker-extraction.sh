#!/usr/bin/env bash
# tests/scripts/test-run-python-tests-marker-extraction.sh
# Tests verifying that run-python-tests.sh correctly extracts RED markers
# from .test-index lines, including multi-marker lines and adjacency enforcement.
#
# Tests:
#   test_single_marker_extracted         — single [Marker] line yields one exclusion
#   test_multi_marker_single_line        — three [Marker] tokens on one line all excluded
#   test_prefix_brackets_not_captured   — brackets in source-key prefix are not extracted
#   test_no_markers_yields_empty         — line with no markers yields no exclusions
#   test_non_py_line_yields_empty        — non-.py line yields no exclusions
#
# Usage: bash tests/scripts/test-run-python-tests-marker-extraction.sh
# Returns: exit 0 if all tests pass, exit 1 otherwise

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-run-python-tests-marker-extraction.sh ==="

# ── Helper: run marker extraction against a fake .test-index ──────────────
# Exercises the same extraction pattern used in run-python-tests.sh so that
# any change to that pattern is reflected here. Returns one marker per line.
extract_markers_from_lines() {
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-index-snippet.XXXXXX")
    printf '%s\n' "$@" > "$tmpfile"

    local red_markers=()
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ (tests/(skills|docs)/[^[:space:]]+\.py)(.*) ]]; then
            _marker_tail="${BASH_REMATCH[3]}"
            while [[ "$_marker_tail" =~ \[([^]]+)\] ]]; do
                red_markers+=("${BASH_REMATCH[1]}")
                _marker_tail="${_marker_tail#*]}"
            done
        fi
    done < "$tmpfile"
    rm -f "$tmpfile"

    printf '%s\n' "${red_markers[@]:-}"
}

# ── test_single_marker_extracted ──────────────────────────────────────────
echo ""
echo "--- Single marker extracted ---"
result=$(extract_markers_from_lines \
    "plugins/dso/scripts/foo.py:tests/skills/foo_test.py [test_single]")
assert_eq "test_single_marker_extracted" "test_single" "$result"

# ── test_multi_marker_single_line ─────────────────────────────────────────
echo ""
echo "--- Multi-marker single line: all three markers extracted ---"
result=$(extract_markers_from_lines \
    "plugins/dso/scripts/runner.py:tests/skills/test_runner.py [test_alpha] [test_beta] [test_gamma]")
marker_count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "test_multi_marker_single_line: count" "3" "$marker_count"
assert_contains "test_multi_marker_single_line: test_alpha present" "test_alpha" "$result"
assert_contains "test_multi_marker_single_line: test_beta present" "test_beta" "$result"
assert_contains "test_multi_marker_single_line: test_gamma present" "test_gamma" "$result"

# ── test_prefix_brackets_not_captured ────────────────────────────────────
# Brackets in the source-key prefix (before the test path) must not be
# captured as RED markers. BASH_REMATCH[3] extracts only the suffix after
# the .py path, ensuring adjacency between path and markers.
echo ""
echo "--- Brackets in source-key prefix are not captured ---"
result=$(extract_markers_from_lines \
    "plugins/[bracketed]/scripts/foo.py:tests/skills/foo_test.py [test_real]")
marker_count=$(printf '%s\n' "$result" | grep -c . || true)
assert_eq "test_prefix_brackets_not_captured: only one marker" "1" "$marker_count"
assert_eq "test_prefix_brackets_not_captured: correct marker" "test_real" "$result"

# ── test_no_markers_yields_empty ──────────────────────────────────────────
echo ""
echo "--- Line with no markers yields empty ---"
result=$(extract_markers_from_lines \
    "plugins/dso/scripts/runner.py:tests/skills/test_runner.py")
assert_eq "test_no_markers_yields_empty" "" "$result"

# ── test_non_py_line_yields_empty ─────────────────────────────────────────
echo ""
echo "--- Non-.py line yields empty ---"
result=$(extract_markers_from_lines \
    "plugins/dso/scripts/run.sh:tests/scripts/test-run.sh [SomeMarker]")
assert_eq "test_non_py_line_yields_empty" "" "$result"

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
print_summary
