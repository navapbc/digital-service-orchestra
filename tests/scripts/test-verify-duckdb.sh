#!/usr/bin/env bash
set -euo pipefail
# tests/scripts/test-verify-duckdb.sh
# RED-phase behavioral tests for plugins/dso/scripts/verify-duckdb.sh
#
# All tests FAIL until the script is implemented (RED gate confirmed).
#
# The verifier checks whether duckdb is installed and reports its version.
# Tests exercise both branches via PATH stubbing — never modifying the real
# DuckDB installation.
#
# Usage: bash tests/scripts/test-verify-duckdb.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/verify-duckdb.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-verify-duckdb.sh ==="

# ── Setup ─────────────────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
cleanup() {
    local d
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    return 0
}
trap cleanup EXIT

make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Test 1: present-binary branch → exits 0, stdout contains OK and version ──
# RED: script does not exist yet — bash invocation will fail immediately.
test_red_verify_duckdb_present_binary() {
    local mock_bin
    mock_bin="$(make_tmpdir)"

    # Write a mock duckdb that echoes a fake version string
    cat > "$mock_bin/duckdb" << 'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "v1.5.3"
    exit 0
fi
exit 0
MOCKEOF
    chmod +x "$mock_bin/duckdb"

    local exit_code=0
    local output
    output=$(
        PATH="$mock_bin:$PATH" bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "test_red_verify_duckdb_present_binary: exits 0 when duckdb is present" \
        "0" "$exit_code"

    assert_contains "test_red_verify_duckdb_present_binary: stdout contains OK" \
        "OK" "$output"

    assert_contains "test_red_verify_duckdb_present_binary: stdout contains version string" \
        "1.5.3" "$output"
}

# ── Test 2: missing-binary branch → exits non-zero, stderr has install hint ──
# RED: script does not exist yet — bash invocation will fail immediately.
test_red_verify_duckdb_missing_binary() {
    local empty_bin
    empty_bin="$(make_tmpdir)"

    # PATH = empty tmpdir + system bins (so bash itself resolves) but no duckdb.
    # Using only `$empty_bin` would prevent bash from finding itself and the
    # script would never execute (exit 127, "command not found" before script runs).
    local exit_code=0
    local output
    output=$(
        PATH="$empty_bin:/usr/bin:/bin" bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_ne "test_red_verify_duckdb_missing_binary: exits non-zero when duckdb is absent" \
        "0" "$exit_code"

    # Must contain an actionable install hint (install, brew, or URL)
    local found_hint=0
    if echo "$output" | grep -qiE 'install|brew|https?://'; then
        found_hint=1
    fi
    assert_eq "test_red_verify_duckdb_missing_binary: stderr contains actionable install hint" \
        "1" "$found_hint"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_red_verify_duckdb_present_binary
test_red_verify_duckdb_missing_binary

print_summary
