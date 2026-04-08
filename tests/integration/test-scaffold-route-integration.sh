#!/usr/bin/env bash
# tests/integration/test-scaffold-route-integration.sh
# Integration tests for scaffold-route recipe via recipe-executor.sh
#
# No external dependencies required (scaffold is a built-in template engine).
#
# Usage: bash tests/integration/test-scaffold-route-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scaffold-route-integration.sh ==="

# Graceful skip
if [[ "${TEST_INTEGRATION_SKIP:-0}" == "1" ]]; then
    echo "SKIP: TEST_INTEGRATION_SKIP=1"
    exit 0
fi

EXECUTOR="$REPO_ROOT/plugins/dso/scripts/recipe-executor.sh"
[[ -f "$EXECUTOR" ]] || { echo "SKIP: recipe-executor.sh not found"; exit 0; }

# Cleanup
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap _cleanup EXIT

# Helper: create temp output dir
_make_output_dir() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    echo "$tmpdir"
}

# test_flask_boilerplate_creation
# Run scaffold-route with FRAMEWORK=flask; verify output files are created with valid Python syntax.

test_flask_boilerplate_creation() {
    local outdir
    outdir="$(_make_output_dir)/src"

    local exit_code=0
    local output
    output=$(bash "$EXECUTOR" scaffold-route \
        --param FRAMEWORK=flask \
        --param ROUTE=users \
        --param OUTPUT_DIR="$outdir" \
        2>&1) || exit_code=$?

    assert_eq "test_flask_boilerplate_creation: exit_code=0" "0" "$exit_code"

    # Output must be valid JSON
    local valid_json=0
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true
    assert_eq "test_flask_boilerplate_creation: output is valid JSON" "1" "$valid_json"

    # files_changed must be non-empty
    local files_count=0
    files_count=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('files_changed', [])))" 2>/dev/null || echo "0")
    assert_ne "test_flask_boilerplate_creation: files_changed non-empty" "0" "$files_count"

    # The generated Python file must have valid syntax
    local py_file="$outdir/users.py"
    if [[ -f "$py_file" ]]; then
        local syntax_ok=0
        python3 -m py_compile "$py_file" 2>/dev/null && syntax_ok=1 || true
        assert_eq "test_flask_boilerplate_creation: generated Python has valid syntax" "1" "$syntax_ok"
    else
        (( ++FAIL ))
        printf "FAIL: test_flask_boilerplate_creation\n  expected users.py at: %s\n" "$py_file" >&2
    fi
}

# test_nextjs_boilerplate_creation
# Run scaffold-route with FRAMEWORK=nextjs; verify output files are created.

test_nextjs_boilerplate_creation() {
    local outdir
    outdir="$(_make_output_dir)/src"

    local exit_code=0
    local output
    output=$(bash "$EXECUTOR" scaffold-route \
        --param FRAMEWORK=nextjs \
        --param ROUTE=products \
        --param OUTPUT_DIR="$outdir" \
        2>&1) || exit_code=$?

    assert_eq "test_nextjs_boilerplate_creation: exit_code=0" "0" "$exit_code"

    # Output must be valid JSON
    local valid_json=0
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true
    assert_eq "test_nextjs_boilerplate_creation: output is valid JSON" "1" "$valid_json"

    # files_changed must be non-empty
    local files_count=0
    files_count=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('files_changed', [])))" 2>/dev/null || echo "0")
    assert_ne "test_nextjs_boilerplate_creation: files_changed non-empty" "0" "$files_count"

    # At least one .ts or .tsx file should exist in output dir
    local ts_count=0
    ts_count=$(find "$outdir" -name "*.ts" -o -name "*.tsx" 2>/dev/null | wc -l | tr -d ' ')
    assert_ne "test_nextjs_boilerplate_creation: TypeScript files created" "0" "$ts_count"
}

# test_scaffold_idempotency
# Running scaffold-route twice on the same output dir with the same route is idempotent:
# second run files_changed=[] (no overwrite without OVERWRITE=1).

test_scaffold_idempotency() {
    local outdir
    outdir="$(_make_output_dir)/src"

    # First run
    local output1
    output1=$(bash "$EXECUTOR" scaffold-route \
        --param FRAMEWORK=flask \
        --param ROUTE=items \
        --param OUTPUT_DIR="$outdir" \
        2>&1) || true

    local files_first=0
    files_first=$(echo "$output1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('files_changed', [])))" 2>/dev/null || echo "-1")
    assert_ne "test_scaffold_idempotency: first run files_changed non-empty" "0" "$files_first"

    # Second run -- no OVERWRITE=1, so existing files should be skipped
    local output2
    output2=$(bash "$EXECUTOR" scaffold-route \
        --param FRAMEWORK=flask \
        --param ROUTE=items \
        --param OUTPUT_DIR="$outdir" \
        2>&1) || true

    local files_second=0
    files_second=$(echo "$output2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('files_changed', [])))" 2>/dev/null || echo "-1")
    assert_eq "test_scaffold_idempotency: second run files_changed=0 (idempotent)" "0" "$files_second"
}

# test_scaffold_determinism
# Three consecutive runs on fresh output dirs produce exit_code=0.

test_scaffold_determinism() {
    local codes=()
    for i in 1 2 3; do
        local outdir
        outdir="$(_make_output_dir)/src"

        local exit_code=0
        bash "$EXECUTOR" scaffold-route \
            --param FRAMEWORK=flask \
            --param ROUTE=health \
            --param OUTPUT_DIR="$outdir" \
            >/dev/null 2>&1 || exit_code=$?
        codes+=("$exit_code")
    done

    assert_eq "test_scaffold_determinism: run1 exit_code=0" "0" "${codes[0]}"
    assert_eq "test_scaffold_determinism: run2 exit_code=0" "0" "${codes[1]}"
    assert_eq "test_scaffold_determinism: run3 exit_code=0" "0" "${codes[2]}"
}

# Run all tests
test_flask_boilerplate_creation
test_nextjs_boilerplate_creation
test_scaffold_idempotency
test_scaffold_determinism

print_summary
