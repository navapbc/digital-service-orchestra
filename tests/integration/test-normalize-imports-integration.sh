#!/usr/bin/env bash
# tests/integration/test-normalize-imports-integration.sh
# Integration tests for normalize-imports recipe via recipe-executor.sh
#
# Tests operate on synthetic fixtures committed to the repo.
# Gracefully skips when external engines (isort, ts-morph) are unavailable.
#
# Usage: bash tests/integration/test-normalize-imports-integration.sh
# Returns: exit 0 if all pass or skip, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-normalize-imports-integration.sh ==="

# Graceful skip
if [[ "${TEST_INTEGRATION_SKIP:-0}" == "1" ]]; then
    echo "SKIP: TEST_INTEGRATION_SKIP=1"
    exit 0
fi

# Fixture availability check
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
if [[ ! -d "$FIXTURES_DIR/python-project" ]] || [[ ! -d "$FIXTURES_DIR/typescript-project" ]]; then
    echo "SKIP: fixtures not available"
    exit 0
fi

# Engine availability checks
ISORT_AVAILABLE=0
if command -v isort >/dev/null 2>&1 || python3 -m isort --version >/dev/null 2>&1; then
    ISORT_AVAILABLE=1
fi

TS_MORPH_AVAILABLE=0
if command -v node >/dev/null 2>&1; then
    if node -e "require('ts-morph')" >/dev/null 2>&1; then
        TS_MORPH_AVAILABLE=1
    fi
fi

EXECUTOR="$REPO_ROOT/plugins/dso/scripts/recipe-executor.sh"
[[ -f "$EXECUTOR" ]] || { echo "SKIP: recipe-executor.sh not found"; exit 0; }

# Cleanup
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap _cleanup EXIT

# Helper: copy fixture to temp dir
_copy_fixture() {
    local fixture_name="$1"
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    cp -r "$FIXTURES_DIR/$fixture_name/." "$tmpdir/"
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "initial fixture"
    echo "$tmpdir"
}

# test_python_normalize_imports
# Run normalize-imports (python/isort) on parser.py which has unsorted/duplicate imports.
# Verify output is valid JSON.

test_python_normalize_imports() {
    if [[ "$ISORT_AVAILABLE" -eq 0 ]]; then
        echo "  SKIP: test_python_normalize_imports (isort unavailable)"
        return
    fi

    local workdir
    workdir="$(_copy_fixture python-project)"

    local exit_code=0
    local output
    output=$(GIT_WORK_TREE="$workdir" bash "$EXECUTOR" normalize-imports \
        --param file="$workdir/src/parser.py" \
        2>&1) || exit_code=$?

    # Output must be valid JSON
    local valid_json=0
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true
    assert_eq "test_python_normalize_imports: output is valid JSON" "1" "$valid_json"

    # exit_code in JSON should be 0
    local json_exit_code="-1"
    json_exit_code=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('exit_code','-1'))" 2>/dev/null || echo "-1")
    assert_eq "test_python_normalize_imports: json exit_code=0" "0" "$json_exit_code"

    # files_changed must be non-empty: parser.py has intentionally unsorted/duplicate imports
    local files_changed_count="-1"
    files_changed_count=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('files_changed', [])))" 2>/dev/null || echo "-1")
    assert_ne "test_python_normalize_imports: files_changed non-empty" "0" "$files_changed_count"
}

# test_typescript_normalize_imports
# Run normalize-imports (typescript) on formatter.ts which has unsorted imports.
# Skip if ts-morph unavailable.

test_typescript_normalize_imports() {
    if [[ "$TS_MORPH_AVAILABLE" -eq 0 ]]; then
        echo "  SKIP: test_typescript_normalize_imports (ts-morph unavailable)"
        return
    fi

    local workdir
    workdir="$(_copy_fixture typescript-project)"

    local exit_code=0
    local output
    output=$(RECIPE_NAME=normalize-imports GIT_WORK_TREE="$workdir" bash "$EXECUTOR" normalize-imports \
        --param file="$workdir/src/formatter.ts" \
        --param project_root="$workdir" \
        2>&1) || exit_code=$?

    # Output must be valid JSON
    local valid_json=0
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true
    assert_eq "test_typescript_normalize_imports: output is valid JSON" "1" "$valid_json"
}

# test_normalize_imports_idempotency
# Run normalize-imports twice on same file; second run should be idempotent.
# Skip if isort unavailable.

test_normalize_imports_idempotency() {
    if [[ "$ISORT_AVAILABLE" -eq 0 ]]; then
        echo "  SKIP: test_normalize_imports_idempotency (isort unavailable)"
        return
    fi

    local workdir
    workdir="$(_copy_fixture python-project)"

    # First run
    GIT_WORK_TREE="$workdir" bash "$EXECUTOR" normalize-imports \
        --param file="$workdir/src/parser.py" \
        >/dev/null 2>&1 || true

    # Commit first-run changes
    git -C "$workdir" add -A >/dev/null 2>&1 || true
    git -C "$workdir" commit -q -m "after first normalize" >/dev/null 2>&1 || true

    # Second run
    local output2
    output2=$(GIT_WORK_TREE="$workdir" bash "$EXECUTOR" normalize-imports \
        --param file="$workdir/src/parser.py" \
        2>&1) || true

    local valid_json=0
    echo "$output2" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true
    assert_eq "test_normalize_imports_idempotency: second run produces valid JSON" "1" "$valid_json"

    # exit_code should be 0 on second run
    local json_exit_code="-1"
    json_exit_code=$(echo "$output2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('exit_code','-1'))" 2>/dev/null || echo "-1")
    assert_eq "test_normalize_imports_idempotency: second run exit_code=0" "0" "$json_exit_code"

    # files_changed must be empty on second run (idempotency check)
    local files_changed_count2="-1"
    files_changed_count2=$(echo "$output2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('files_changed', [])))" 2>/dev/null || echo "-1")
    assert_eq "test_normalize_imports_idempotency: second run files_changed=[]" "0" "$files_changed_count2"
}

# test_normalize_imports_determinism
# Three consecutive runs on fresh fixtures produce same exit_code=0.
# Skip if isort unavailable.

test_normalize_imports_determinism() {
    if [[ "$ISORT_AVAILABLE" -eq 0 ]]; then
        echo "  SKIP: test_normalize_imports_determinism (isort unavailable)"
        return
    fi

    local codes=()
    for i in 1 2 3; do
        local workdir
        workdir="$(_copy_fixture python-project)"

        local exit_code=0
        GIT_WORK_TREE="$workdir" bash "$EXECUTOR" normalize-imports \
            --param file="$workdir/src/parser.py" \
            >/dev/null 2>&1 || exit_code=$?
        codes+=("$exit_code")
    done

    assert_eq "test_normalize_imports_determinism: run1 exit_code=0" "0" "${codes[0]}"
    assert_eq "test_normalize_imports_determinism: run2 exit_code=0" "0" "${codes[1]}"
    assert_eq "test_normalize_imports_determinism: run3 exit_code=0" "0" "${codes[2]}"
}

# Run all tests
test_python_normalize_imports
test_typescript_normalize_imports
test_normalize_imports_idempotency
test_normalize_imports_determinism

print_summary
