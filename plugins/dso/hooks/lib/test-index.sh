#!/usr/bin/env bash
# lib/test-index.sh — .test-index parsing helpers for record-test-status
#
# Provides:
#   read_test_index_for_source <src_file>
#   find_global_red_marker_for_test <test_file_path>
#
# Guard: sourced at most once per shell process.
[[ -n "${_DSO_TEST_INDEX_LOADED:-}" ]] && return 0
_DSO_TEST_INDEX_LOADED=1

# ── .test-index parsing ──────────────────────────────────────────────────────
# Reads $REPO_ROOT/.test-index and returns test paths mapped to a given source file.
# Format per line: 'source/path.ext: test/path1.ext [marker], test/path2.ext'
#   - Lines starting with # are comments; blank lines are ignored
#   - Colons and commas in paths are not supported
#   - Empty right-hand side = no association for that line
#   - Optional [first_red_test_name] after a test path enables RED zone tolerance
# Returns lines on stdout: "test/path.ext" or "test/path.ext [marker_name]"
# Missing file = no output (no error). Nonexistent test paths: warning to stderr, skipped.
read_test_index_for_source() {
    local src_file="$1"
    local repo_root="${REPO_ROOT:-.}"
    local index_file="${repo_root}/.test-index"

    if [[ ! -f "$index_file" ]]; then
        echo "INFO: .test-index not found, using fuzzy match only" >&2
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank lines
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Split on first colon: left = source path, right = comma-separated test paths
        local left="${line%%:*}"
        local right="${line#*:}"

        # Trim whitespace from left side
        left="${left#"${left%%[![:space:]]*}"}"
        left="${left%"${left##*[![:space:]]}"}"

        # Match against the source file
        if [[ "$left" != "$src_file" ]]; then
            continue
        fi

        # Split right side on commas and emit each non-empty test path (with optional [marker])
        # Declare parts and part as local to prevent clobbering caller variables.
        local parts part
        IFS=',' read -ra parts <<< "$right"
        for part in "${parts[@]}"; do
            # Trim leading/trailing whitespace
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            if [[ -n "$part" ]]; then
                # Extract optional [marker_name] suffix: "test/path.ext [marker]"
                local test_path marker_name
                if [[ "$part" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                    test_path="${BASH_REMATCH[1]}"
                    marker_name="${BASH_REMATCH[2]}"
                    # Trim trailing whitespace from test_path
                    test_path="${test_path%"${test_path##*[![:space:]]}"}"
                else
                    test_path="$part"
                    marker_name=""
                fi

                local full_path="${repo_root}/${test_path}"
                if [[ ! -f "$full_path" ]]; then
                    echo "WARNING: .test-index entry points to nonexistent file: $test_path" >&2
                    continue
                fi
                if [[ -n "$marker_name" ]]; then
                    echo "${test_path} [${marker_name}]"
                else
                    echo "$test_path"
                fi
            fi
        done
    done < "$index_file"
}

# find_global_red_marker_for_test: scan ALL .test-index entries (regardless of
# source file) to find a RED marker for a given test file path.
# Bug B fix (b9a9-4cb3): when a test is triggered by a staged source whose
# .test-index entry has no marker, a different source's entry may have one.
# This function performs a proper parse (not substring grep) to avoid false
# positives from overlapping filenames (e.g., "test_alpha.sh" must not match
# a marker on "test_alpha_extended.sh").
#
# Usage: find_global_red_marker_for_test <test_file_path>
# Returns: marker name on stdout (empty string if none found)
find_global_red_marker_for_test() {
    local target_test="$1"
    local repo_root="${REPO_ROOT:-.}"
    local index_file="${repo_root}/.test-index"

    [[ -f "$index_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Split on first colon: left = source, right = comma-separated tests
        local right="${line#*:}"

        # Declare parts and part as local to prevent clobbering caller variables.
        local parts part
        IFS=',' read -ra parts <<< "$right"
        for part in "${parts[@]}"; do
            # Trim whitespace
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

            # Exact path match (not substring) — hardened for overlapping names
            if [[ "$parsed_path" == "$target_test" ]] && [[ -n "$parsed_marker" ]]; then
                echo "$parsed_marker"
                return 0
            fi
        done
    done < "$index_file"
}
