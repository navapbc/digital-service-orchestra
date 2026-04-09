#!/usr/bin/env bash
# plugins/dso/hooks/lib/red-zone.sh
# Shared RED zone helpers for record-test-status.sh and test infrastructure.
#
# Usage (source into scripts):
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/red-zone.sh"
#
# Provides:
#   get_red_zone_line_number(test_file, marker_name)
#     → line number of marker in test file, or -1 if not found
#   parse_failing_tests_from_output(output_file)
#     → one failing test name per line on stdout
#   get_test_line_number(test_file, test_name)
#     → line number of test function in test file, or -1 if not found
#   read_red_markers_by_test_file(assoc_array_name)
#     → populates caller's associative array: test_file_path → marker_name
#       (reads all entries from $REPO_ROOT/.test-index)
#
# Environment:
#   REPO_ROOT — repo root directory (defaults to ".")
#
# Extracted from plugins/dso/hooks/record-test-status.sh.

# ── RED zone helpers ──────────────────────────────────────────────────────────

# get_red_zone_line_number: find line number of marker in a test file.
# For Python: matches 'def marker_name' or 'def marker_name('
# For Bash: matches 'marker_name()' or 'marker_name (' or '# marker_name' pattern
# For plain text / other: matches any line containing the marker name
# For Class::method format (pytest class-based tests): when marker_name contains '::',
#   split on '::' to get class_name and method_name, then scan the file for the
#   class definition first, and only match the method def within that class scope.
# Returns the line number on stdout, or -1 if not found.
# Emits WARNING to stderr if marker provided but not found.
get_red_zone_line_number() {
    local test_file="$1"
    local marker_name="$2"
    local repo_root="${REPO_ROOT:-.}"
    local full_path="${repo_root}/${test_file}"

    if [[ ! -f "$full_path" ]]; then
        echo "-1"
        return 0
    fi

    local found_line=-1

    # Handle Class::method format (pytest class-based test IDs)
    if [[ "$marker_name" == *::* ]]; then
        local class_name="${marker_name%%::*}"
        local method_name="${marker_name#*::}"
        # Word-boundary patterns for class and method
        local pat_class="(^|[^a-zA-Z0-9_-])${class_name}([^a-zA-Z0-9_-]|\$)"
        local pat_method="(^|[^a-zA-Z0-9_-])${method_name}([^a-zA-Z0-9_-]|\$)"
        local line_num=0
        local in_class=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            (( line_num++ )) || true
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            # Detect class definition: "class ClassName" or "class ClassName:"
            if [[ $in_class -eq 0 ]] && [[ "$line" =~ $pat_class ]]; then
                in_class=1
                continue
            fi
            # Once inside the class, look for the method definition
            if [[ $in_class -eq 1 ]]; then
                # A new top-level class/def (no leading whitespace) signals we left the class
                if [[ "$line" =~ ^[^[:space:]] ]] && [[ ! -z "$line" ]]; then
                    # Allow "class " or "def " at top level — we've left the previous class
                    in_class=0
                    continue
                fi
                if [[ "$line" =~ $pat_method ]]; then
                    found_line=$line_num
                    break
                fi
            fi
        done < "$full_path"

        if [[ $found_line -eq -1 ]]; then
            echo "WARNING: RED marker '${marker_name}' not found in test file: ${test_file}" >&2
        fi
        echo "$found_line"
        return 0
    fi

    local line_num=0
    # Word-boundary pattern: marker_name not adjacent to other identifier chars [a-zA-Z0-9_-]
    # Hyphens are included so that searching for 'test-foo' does not match 'test-foo-bar',
    # and searching for 'test' does not accidentally match 'test-foo'.
    local pat_word_boundary="(^|[^a-zA-Z0-9_-])${marker_name}([^a-zA-Z0-9_-]|\$)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num++ )) || true
        # Skip pure comment lines (lines starting with optional whitespace then #)
        # to avoid false positives from comment-only mentions
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Match marker_name as a word (not adjacent to other identifier chars)
        if [[ "$line" =~ $pat_word_boundary ]]; then
            found_line=$line_num
            break
        fi
    done < "$full_path"

    if [[ $found_line -eq -1 ]]; then
        echo "WARNING: RED marker '${marker_name}' not found in test file: ${test_file}" >&2
    fi
    echo "$found_line"
}

# parse_failing_tests_from_output: extract failing test names from test runner output.
# Supports:
#   - Bash-style: "test_name: FAIL..." lines
#   - Pytest FAILED lines: "FAILED path/to/test.py::test_name"
#   - Jest-style: "● Suite > test name" or "✕ test name"
# Returns one test name per line on stdout.
parse_failing_tests_from_output() {
    local output_file="$1"

    if [[ ! -f "$output_file" ]]; then
        return 0
    fi

    # Bash-style: "test_name: FAIL" (test_name is word chars + underscores/hyphens)
    grep -oE '^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*:[[:space:]]*FAIL' "$output_file" \
        | sed 's/[[:space:]]*:[[:space:]]*FAIL//' \
        || true

    # Bash-style (assert_pass_if_clean): "FAIL: test_name" on stderr merged into output
    # Full-line match with end-of-line anchor ensures multi-word assert_eq labels
    # (e.g., "FAIL: ticket ID returned for --tags test") are NOT extracted as
    # partial words. Only lines where the content after "FAIL: " is a single
    # identifier are matched (bug 091a-368f).
    grep -E '^[[:space:]]*FAIL: [a-zA-Z_][a-zA-Z0-9_-]*$' "$output_file" \
        | sed 's/^[[:space:]]*FAIL: //' \
        || true

    # Pytest-style: "FAILED path/to/test.py::test_name" or "FAILED path/to/test.py::ClassName::test_name"
    # Extract the last ::segment to handle class-based tests
    grep -oE '^FAILED [^[:space:]]+::[a-zA-Z_][a-zA-Z0-9_]*(::[a-zA-Z_][a-zA-Z0-9_]*)?' "$output_file" \
        | sed 's/^FAILED .*:://' \
        || true

    # Jest-style verbose: "● Suite > test name" — extract segment after last " > "
    grep -E '^[[:space:]]*● ' "$output_file" \
        | sed 's/.*>[[:space:]]*//' \
        | sed 's/[[:space:]]*$//' \
        || true

    # Jest-style compact: "✕ test name" — extract the test name after ✕
    grep -E '^[[:space:]]*✕ ' "$output_file" \
        | sed 's/^[[:space:]]*✕[[:space:]]*//' \
        | sed 's/[[:space:]]*$//' \
        || true
}

# parse_passing_tests_from_output: extract passing test names from test runner output.
# Mirrors parse_failing_tests_from_output for the pass case.
# Supports:
#   - Bash-style: "test_name ... PASS" or "test_name: PASS"
#   - Pytest PASSED lines: "PASSED path/to/test.py::test_name"
# Returns one test name per line on stdout.
parse_passing_tests_from_output() {
    local output_file="$1"

    if [[ ! -f "$output_file" ]]; then
        return 0
    fi

    # Bash-style: "test_name ... PASS" (with optional whitespace/dots between)
    grep -oE '^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*\.\.\..*PASS' "$output_file" \
        | sed 's/[[:space:]]*\.\.\..*PASS//' \
        || true

    # Bash-style: "test_name: PASS"
    grep -oE '^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*:[[:space:]]*PASS' "$output_file" \
        | sed 's/[[:space:]]*:[[:space:]]*PASS//' \
        || true

    # Pytest-style: "PASSED path/to/test.py::test_name" or "PASSED path/to/test.py::ClassName::test_name"
    # Extract the last ::segment to handle class-based tests
    grep -oE '^PASSED [^[:space:]]+::[a-zA-Z_][a-zA-Z0-9_]*(::[a-zA-Z_][a-zA-Z0-9_]*)?' "$output_file" \
        | sed 's/^PASSED .*:://' \
        || true
}

# get_test_line_number: find the line number of a test function in a test file.
# For Python: 'def test_name('
# For Bash: 'test_name()' or any line containing test_name as a word
# Returns -1 if not found.
get_test_line_number() {
    local test_file="$1"
    local test_name="$2"
    local repo_root="${REPO_ROOT:-.}"
    local full_path="${repo_root}/${test_file}"

    if [[ ! -f "$full_path" ]]; then
        echo "-1"
        return 0
    fi

    local line_num=0
    # Word-boundary pattern: test_name not adjacent to other identifier chars [a-zA-Z0-9_-]
    # Hyphens are included so that searching for 'test-foo' does not match 'test-foo-bar',
    # and searching for 'test' does not accidentally match 'test-foo'.
    local pat_word_boundary="(^|[^a-zA-Z0-9_-])${test_name}([^a-zA-Z0-9_-]|\$)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num++ )) || true
        # Skip pure comment lines to avoid false positives
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ $pat_word_boundary ]]; then
            echo "$line_num"
            return 0
        fi
    done < "$full_path"

    echo "-1"
}

# read_red_markers_by_test_file: scan $REPO_ROOT/.test-index and populate an
# associative array mapping test_file_path → marker_name for all entries that
# have a [marker] annotation.
#
# Usage:
#   declare -A my_map=()
#   REPO_ROOT="/path/to/repo" read_red_markers_by_test_file my_map
#
# Parameters:
#   $1 — name of caller's associative array (passed by name, populated via nameref)
#
# Semantics:
#   - Entries without a [marker] result in an empty-string value for that test file.
#   - When the same test file appears in multiple source entries, a non-empty marker
#     is never overwritten by an empty one (Bug A fix: mirrors record-test-status.sh logic).
#   - Comments (lines starting with #) and blank lines are skipped.
#   - Missing .test-index file silently produces an empty result.
#
# Environment:
#   REPO_ROOT — defaults to "."
read_red_markers_by_test_file() {
    local -n _rrmbtf_map="$1"
    local repo_root="${REPO_ROOT:-.}"
    local index_file="${repo_root}/.test-index"

    if [[ ! -f "$index_file" ]]; then
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank lines
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Split on first colon: left = source path, right = comma-separated test entries
        local right="${line#*:}"

        # Parse each comma-separated test entry
        # Declare parts and part as local to prevent clobbering caller variables
        # when read_red_markers_by_test_file is called directly (not in a subshell).
        local parts part
        IFS=',' read -ra parts <<< "$right"
        for part in "${parts[@]}"; do
            # Trim leading/trailing whitespace
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            [[ -z "$part" ]] && continue

            # Parse "test/path.ext [marker_name]" or just "test/path.ext"
            local parsed_path parsed_marker
            if [[ "$part" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                parsed_path="${BASH_REMATCH[1]}"
                parsed_marker="${BASH_REMATCH[2]}"
                # Trim trailing whitespace from path
                parsed_path="${parsed_path%"${parsed_path##*[![:space:]]}"}"
            else
                parsed_path="$part"
                parsed_marker=""
            fi

            # Bug A fix: non-empty marker must not be overwritten by an empty one.
            # Only overwrite if new marker is non-empty OR no entry exists yet.
            if [[ -n "$parsed_marker" ]] || [[ -z "${_rrmbtf_map[$parsed_path]:-}" ]]; then
                _rrmbtf_map["$parsed_path"]="$parsed_marker"
            fi
        done
    done < "$index_file"
}
