#!/usr/bin/env bash
# plugins/dso/hooks/lib/fuzzy-match.sh
# Shared fuzzy match library for tech-stack-agnostic test file association.
#
# Provides:
#   fuzzy_normalize <string>         — strip non-alphanumeric, lowercase
#   fuzzy_is_test_file <filename>    — detect test files by naming convention
#   fuzzy_find_associated_tests <src_file> <repo_root> [test_dirs]
#                                    — find test files matching a source file

# Guard: only load once
[[ "${_FUZZY_MATCH_LOADED:-}" == "1" ]] && return 0
_FUZZY_MATCH_LOADED=1

# --- _fuzzy_normalize_var ---
# Internal: normalize into a named variable (no subshell).
# Usage: _fuzzy_normalize_var <string> <varname>
_fuzzy_normalize_var() {
    local _input="$1"
    # Lowercase
    _input="${_input,,}"
    # Strip non-alphanumeric via parameter expansion
    local _result=""
    local _i _c
    for (( _i=0; _i<${#_input}; _i++ )); do
        _c="${_input:_i:1}"
        [[ "$_c" == [a-z0-9] ]] && _result+="$_c"
    done
    printf -v "$2" '%s' "$_result"
}

# --- fuzzy_normalize ---
# Strip all non-alphanumeric characters, lowercase.
# e.g. bump-version.sh -> bumpversionsh
fuzzy_normalize() {
    local input="$1"
    local _out
    _fuzzy_normalize_var "$input" _out
    printf '%s\n' "$_out"
}

# --- fuzzy_is_test_file ---
# Detect test files by naming convention. Returns 0 (true) if test file.
# Handles: test_*.py, test-*.sh, *.test.ts, *.spec.ts, *.test.js, *.spec.js, *_test.go, test-*.*, test_*.*
fuzzy_is_test_file() {
    local filename="$1"
    local base
    base=$(basename "$filename")
    [[ "$base" == test_* ]] || [[ "$base" == test-* ]] || \
    [[ "$base" == *.test.* ]] || [[ "$base" == *.spec.* ]] || \
    [[ "$base" == *_test.* ]]
}

# --- fuzzy_find_associated_tests ---
# Find test files that match a source file via normalized substring matching.
#
# Usage: fuzzy_find_associated_tests <src_file> <repo_root> [test_dirs]
#   src_file  — absolute path to source file
#   repo_root — absolute path to repo root
#   test_dirs — optional: space/colon-separated list of dirs to search (relative to repo_root)
#               If omitted, searches the entire repo.
#
# Output: one matching test file path per line (relative to repo_root)
fuzzy_find_associated_tests() {
    local src_file="$1"
    local repo_root="$2"
    local test_dirs="${3:-}"

    # Bash builtin basename: strip everything up to last /
    local src_base="${src_file##*/}"
    local norm_src
    _fuzzy_normalize_var "$src_base" norm_src

    # Safety guard: empty normalized source returns nothing
    [[ -z "$norm_src" ]] && return 0

    local search_paths=()
    if [[ -n "$test_dirs" ]]; then
        # Split test_dirs on colon or space
        local IFS=': '
        local dir
        for dir in $test_dirs; do
            [[ -z "$dir" ]] && continue
            local sp="${repo_root}/${dir}"
            [[ -d "$sp" ]] && search_paths+=("$sp")
        done
    else
        # No test_dirs specified — search entire repo
        search_paths+=("$repo_root")
    fi

    local search_path
    for search_path in "${search_paths[@]}"; do
        while IFS= read -r test_file; do
            [[ -z "$test_file" ]] && continue
            # Bash builtin basename
            local test_base="${test_file##*/}"
            # Quick test-file check inline (avoid function call overhead)
            case "$test_base" in
                test_*|test-*) ;;
                *.test.*|*.spec.*|*_test.*) ;;
                *) continue ;;
            esac
            local norm_test
            _fuzzy_normalize_var "$test_base" norm_test
            # Match: normalized source is a substring of normalized test name
            if [[ "$norm_test" == *"$norm_src"* ]]; then
                echo "${test_file#"$repo_root/"}"
            fi
        done < <(find "$search_path" -type f \
            -not -path '*/node_modules/*' \
            -not -path '*/.venv/*' \
            -not -path '*/vendor/*' \
            -not -path '*/bower_components/*' \
            -not -path '*/__pypackages__/*' \
            -not -path '*/.gradle/*' \
            -not -path '*/Pods/*' \
            -not -path '*/.git/*' \
            2>/dev/null)
    done
}
