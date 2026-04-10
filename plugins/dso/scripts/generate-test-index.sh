#!/usr/bin/env bash
set -uo pipefail
# generate-test-index.sh — Scan source files, find test associations that fuzzy match misses,
# and write a .test-index file for the test gate.
#
# For each source file:
#   1. Run fuzzy_find_associated_tests() against configured test_dirs
#   2. If fuzzy misses, do a broader token-based scan across the entire repo
#   3. If broader scan finds a test: write to .test-index (INDEX CANDIDATE)
#   4. If fuzzy found it: skip (FUZZY MATCH)
#   5. If no test found anywhere: skip (NO COVERAGE)
#
# Usage:
#   generate-test-index.sh [--repo-root <path>] [--test-dirs <dirs>] [--src-dirs <dirs>] [--output <path>]
#
# Flags:
#   --repo-root   Repository root (default: git rev-parse --show-toplevel)
#   --test-dirs   Colon-separated test directories (default: from dso-config.conf or tests/)
#   --src-dirs    Colon-separated source directories (default: plugins/:scripts/:app/:src/)
#   --output      Output file path (default: <repo-root>/.test-index)
#
# Exit codes:
#   0  — success

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Parse arguments ---
REPO_ROOT=""
TEST_DIRS=""
SRC_DIRS=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)  REPO_ROOT="$2"; shift 2 ;;
        --repo-root=*) REPO_ROOT="${1#*=}"; shift ;;
        --test-dirs)  TEST_DIRS="$2"; shift 2 ;;
        --test-dirs=*) TEST_DIRS="${1#*=}"; shift ;;
        --src-dirs)   SRC_DIRS="$2"; shift 2 ;;
        --src-dirs=*)  SRC_DIRS="${1#*=}"; shift ;;
        --output)     OUTPUT="$2"; shift 2 ;;
        --output=*)    OUTPUT="${1#*=}"; shift ;;
        *)
            echo "Usage: generate-test-index.sh [--repo-root <path>] [--test-dirs <dirs>] [--src-dirs <dirs>] [--output <path>]" >&2
            exit 1
            ;;
    esac
done

# --- Defaults ---
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$REPO_ROOT/.test-index"
fi

# Source fuzzy-match library
source "$PLUGIN_ROOT/hooks/lib/fuzzy-match.sh"

# --- Resolve test_dirs ---
if [[ -z "$TEST_DIRS" ]]; then
    # Try reading from dso-config.conf
    local_config="$REPO_ROOT/.claude/dso-config.conf"
    if [[ -f "$local_config" ]]; then
        TEST_DIRS=$(grep '^test_gate\.test_dirs=' "$local_config" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)
    fi
    if [[ -z "$TEST_DIRS" ]]; then
        TEST_DIRS="tests"
    fi
fi

# --- Resolve src_dirs ---
if [[ -z "$SRC_DIRS" ]]; then
    SRC_DIRS="plugins:scripts:app:src"
fi

# --- Check test_dirs exist ---
IFS=':' read -ra test_dir_arr <<< "$TEST_DIRS"
valid_test_dirs=()
missing_test_dirs=()
for td in "${test_dir_arr[@]}"; do
    [[ -z "$td" ]] && continue
    if [[ -d "$REPO_ROOT/$td" ]]; then
        valid_test_dirs+=("$td")
    else
        missing_test_dirs+=("$td")
    fi
done

for md in "${missing_test_dirs[@]}"; do
    echo "WARNING: test directory '$md' does not exist in $REPO_ROOT" >&2
done

# --- Build source file list ---
IFS=':' read -ra src_dir_arr <<< "$SRC_DIRS"
src_files=()
for sd in "${src_dir_arr[@]}"; do
    [[ -z "$sd" ]] && continue
    [[ ! -d "$REPO_ROOT/$sd" ]] && continue
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        src_files+=("$f")
    done < <(find "$REPO_ROOT/$sd" -type f \
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

# --- Helper: broader token-based scan ---
# Splits source basename (without extension) into tokens on non-alphanumeric boundaries,
# normalizes each, and checks if ALL tokens appear in the normalized test basename.
# Also requires the test basename to contain 'test'.
_broader_scan_find_tests() {
    local src_file="$1"
    local repo_root="$2"

    local src_base="${src_file##*/}"
    # Strip extension
    local src_name="${src_base%.*}"

    # Split source name into tokens (on _ - . and other non-alnum)
    local tokens=()
    local token=""
    local i c
    local lower_name="${src_name,,}"
    for (( i=0; i<${#lower_name}; i++ )); do
        c="${lower_name:i:1}"
        if [[ "$c" == [a-z0-9] ]]; then
            token+="$c"
        else
            if [[ -n "$token" ]]; then
                tokens+=("$token")
                token=""
            fi
        fi
    done
    [[ -n "$token" ]] && tokens+=("$token")

    # Safety: need at least one token
    [[ ${#tokens[@]} -eq 0 ]] && return 0

    # Scan cached file list — _all_repo_files is populated once before the main
    # source-file loop to avoid O(n*m) find calls (fixes w20-gm71).
    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        local test_base="${test_file##*/}"

        # Quick test-file check
        case "$test_base" in
            test_*|test-*) ;;
            *.test.*|*.spec.*|*_test.*) ;;
            *) continue ;;
        esac

        local norm_test
        _fuzzy_normalize_var "$test_base" norm_test

        # Check that 'test' appears in normalized name
        [[ "$norm_test" != *test* ]] && continue

        # Check ALL source tokens appear in normalized test name
        local all_match=true
        local t
        for t in "${tokens[@]}"; do
            if [[ "$norm_test" != *"$t"* ]]; then
                all_match=false
                break
            fi
        done

        if [[ "$all_match" == "true" ]]; then
            echo "${test_file#"$repo_root/"}"
        fi
    done < <(printf '%s\n' "${_all_repo_files[@]}")
}

# --- Main scan ---
count_fuzzy=0
count_index=0
count_nocoverage=0

# Associative array for index entries: source -> comma-separated test paths
declare -A index_entries

# Cache all repo files once so _broader_scan_find_tests can iterate the list
# without re-running find for each source file (fixes O(n*m) performance, w20-gm71).
_all_repo_files=()
while IFS= read -r _f; do
    [[ -n "$_f" ]] && _all_repo_files+=("$_f")
done < <(find "$REPO_ROOT" -type f \
    -not -path '*/node_modules/*' \
    -not -path '*/.venv/*' \
    -not -path '*/vendor/*' \
    -not -path '*/bower_components/*' \
    -not -path '*/__pypackages__/*' \
    -not -path '*/.gradle/*' \
    -not -path '*/Pods/*' \
    -not -path '*/.git/*' \
    2>/dev/null)

for src_file in "${src_files[@]}"; do
    # Skip test files
    if fuzzy_is_test_file "$src_file"; then
        continue
    fi

    local_rel="${src_file#"$REPO_ROOT/"}"

    # Step 1: fuzzy match against configured test_dirs
    fuzzy_test_dirs_str=""
    for vtd in "${valid_test_dirs[@]}"; do
        [[ -n "$fuzzy_test_dirs_str" ]] && fuzzy_test_dirs_str+=":"
        fuzzy_test_dirs_str+="$vtd"
    done

    fuzzy_results=""
    if [[ -n "$fuzzy_test_dirs_str" ]]; then
        fuzzy_results=$(fuzzy_find_associated_tests "$src_file" "$REPO_ROOT" "$fuzzy_test_dirs_str")
    fi

    if [[ -n "$fuzzy_results" ]]; then
        # FUZZY MATCH — no .test-index entry needed
        (( count_fuzzy++ ))
        continue
    fi

    # Step 2: broader scan across entire repo
    broader_results=$(_broader_scan_find_tests "$src_file" "$REPO_ROOT")

    if [[ -n "$broader_results" ]]; then
        # INDEX CANDIDATE — fuzzy missed but broader scan found tests
        (( count_index++ ))
        # Collect test paths (comma-separated)
        test_paths=""
        while IFS= read -r tp; do
            [[ -z "$tp" ]] && continue
            if [[ -n "$test_paths" ]]; then
                test_paths+=", $tp"
            else
                test_paths="$tp"
            fi
        done <<< "$broader_results"
        index_entries["$local_rel"]="$test_paths"
    else
        # NO COVERAGE
        (( count_nocoverage++ ))
    fi
done

# --- Write .test-index atomically ---
if [[ ${#index_entries[@]} -gt 0 ]]; then
    tmp_file=$(mktemp "$REPO_ROOT/.test-index.XXXXXX")
    {
        echo "# .test-index — auto-generated by generate-test-index.sh"
        echo "# Maps source files to test files that fuzzy match misses."
        echo "# Format: source/path: test/path1[, test/path2...]"
        echo ""
        # Sort keys for deterministic output
        for key in $(printf '%s\n' "${!index_entries[@]}" | sort); do
            echo "$key: ${index_entries[$key]}"
        done
    } > "$tmp_file"
    mv "$tmp_file" "$OUTPUT"
elif [[ -f "$OUTPUT" ]]; then
    # No index candidates — write an empty (header-only) file
    tmp_file=$(mktemp "$REPO_ROOT/.test-index.XXXXXX")
    {
        echo "# .test-index — auto-generated by generate-test-index.sh"
        echo "# Maps source files to test files that fuzzy match misses."
        echo "# Format: source/path: test/path1[, test/path2...]"
    } > "$tmp_file"
    mv "$tmp_file" "$OUTPUT"
fi

# --- Coverage summary ---
echo "Files with fuzzy matches: $count_fuzzy"
echo "Files with .test-index entries: $count_index"
echo "Files with no test coverage (no-coverage): $count_nocoverage"

exit 0
