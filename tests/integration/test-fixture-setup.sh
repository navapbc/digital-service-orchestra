#!/usr/bin/env bash
# tests/integration/test-fixture-setup.sh
# Tests for tests/integration/setup-fixtures.sh
#
# Usage: bash tests/integration/test-fixture-setup.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-fixture-setup.sh ==="

# Graceful skip
if [[ "${TEST_INTEGRATION_SKIP:-0}" == "1" ]]; then
    echo "SKIP: TEST_INTEGRATION_SKIP=1"
    exit 0
fi

SETUP_SCRIPT="$SCRIPT_DIR/setup-fixtures.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# test_creates_fixture_dir
# setup-fixtures.sh exits non-zero when FIXTURES_OVERRIDE points to an empty dir
# (fixtures missing), and exits 0 when pointing to real committed fixtures.

test_creates_fixture_dir() {
    # Verify setup-fixtures.sh exists
    if [[ ! -f "$SETUP_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_creates_fixture_dir\n  setup-fixtures.sh not found at: %s\n" "$SETUP_SCRIPT" >&2
        return
    fi

    # Case 1: FIXTURES_OVERRIDE points to an empty temp dir -- script should exit non-zero
    local tmp_fixtures
    tmp_fixtures="$(mktemp -d)"
    trap "rm -rf '$tmp_fixtures'" RETURN

    local rc_missing=0
    FIXTURES_OVERRIDE="$tmp_fixtures" bash "$SETUP_SCRIPT" 2>/dev/null || rc_missing=$?
    assert_ne "test_creates_fixture_dir: exits non-zero when fixtures missing" "0" "$rc_missing"

    # Case 2: FIXTURES_OVERRIDE points to the real committed fixtures -- script should exit 0
    local rc_present=0
    FIXTURES_OVERRIDE="$FIXTURES_DIR" bash "$SETUP_SCRIPT" 2>/dev/null || rc_present=$?
    assert_eq "test_creates_fixture_dir: exits 0 when fixtures present" "0" "$rc_present"
}

# test_python_fixture_exists
# After setup, python-project dir exists with pyproject.toml

test_python_fixture_exists() {
    if [[ ! -f "$SETUP_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_python_fixture_exists\n  setup-fixtures.sh not found\n" >&2
        return
    fi

    bash "$SETUP_SCRIPT" 2>/dev/null
    local rc=$?
    assert_eq "test_python_fixture_exists: exit code" "0" "$rc"

    if [[ -f "$FIXTURES_DIR/python-project/pyproject.toml" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_python_fixture_exists\n  python-project/pyproject.toml not found at: %s\n" "$FIXTURES_DIR/python-project/pyproject.toml" >&2
    fi
}

# test_python_fixture_has_source_files
# After setup, 8+ .py files exist in python-project

test_python_fixture_has_source_files() {
    if [[ ! -f "$SETUP_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_python_fixture_has_source_files\n  setup-fixtures.sh not found\n" >&2
        return
    fi

    bash "$SETUP_SCRIPT" 2>/dev/null

    local py_count
    py_count=$(find "$FIXTURES_DIR/python-project" -name "*.py" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$py_count" -ge 8 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_python_fixture_has_source_files\n  expected 8+ .py files, found: %s\n" "$py_count" >&2
    fi
}

# test_typescript_fixture_exists
# typescript-project dir exists with tsconfig.json

test_typescript_fixture_exists() {
    if [[ ! -f "$SETUP_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_typescript_fixture_exists\n  setup-fixtures.sh not found\n" >&2
        return
    fi

    bash "$SETUP_SCRIPT" 2>/dev/null

    if [[ -f "$FIXTURES_DIR/typescript-project/tsconfig.json" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_typescript_fixture_exists\n  typescript-project/tsconfig.json not found at: %s\n" "$FIXTURES_DIR/typescript-project/tsconfig.json" >&2
    fi
}

# test_typescript_fixture_has_source_files
# 8+ .ts files in typescript-project

test_typescript_fixture_has_source_files() {
    if [[ ! -f "$SETUP_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_typescript_fixture_has_source_files\n  setup-fixtures.sh not found\n" >&2
        return
    fi

    bash "$SETUP_SCRIPT" 2>/dev/null

    local ts_count
    ts_count=$(find "$FIXTURES_DIR/typescript-project" -name "*.ts" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ts_count" -ge 8 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_typescript_fixture_has_source_files\n  expected 8+ .ts files, found: %s\n" "$ts_count" >&2
    fi
}

# Run all tests
test_creates_fixture_dir
test_python_fixture_exists
test_python_fixture_has_source_files
test_typescript_fixture_exists
test_typescript_fixture_has_source_files

print_summary
