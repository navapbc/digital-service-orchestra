#!/usr/bin/env bash
# tests/hooks/test-aggregator-behavior.sh
# TDD tests for run-hook-tests.sh aggregator behavior.
#
# Tests:
#   1. Aggregator exits non-zero when a test file exits with failure
#   2. Aggregator exits zero when all test files pass
#   3. Aggregator prints "Hook Tests: PASSED: N  FAILED: N" summary line
#
# Usage: bash tests/hooks/test-aggregator-behavior.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGGREGATOR="$SCRIPT_DIR/run-hook-tests.sh"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

source "$LIB_DIR/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ============================================================
# Helpers
# ============================================================

# Create a temporary directory to act as an isolated "hooks test dir"
# with a copy of the aggregator, lib/, and only the mock test files we control.
make_isolated_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    # Copy aggregator into the temp dir (the aggregator globs test-*.sh in $(dirname $0))
    cp "$AGGREGATOR" "$tmpdir/run-hook-tests.sh"
    chmod +x "$tmpdir/run-hook-tests.sh"
    # Copy lib/ so suite-engine.sh can be sourced by the aggregator
    mkdir -p "$tmpdir/../lib"
    cp "$LIB_DIR"/*.sh "$tmpdir/../lib/"
    echo "$tmpdir"
}

cleanup_dir() {
    local dir="$1"
    rm -rf "$dir"
}

# ============================================================
# Test 1: Aggregator exits non-zero when a test file fails
# ============================================================
echo "--- Test 1: aggregator exits non-zero on failure ---"

TMPDIR1=$(make_isolated_dir)

# Write a mock failing test file: increments FAIL, exits 1
cat > "$TMPDIR1/test-mock-failing.sh" << 'EOF'
#!/usr/bin/env bash
PASS=0
FAIL=1
echo "Results: 0 passed, 1 failed"
exit 1
EOF
chmod +x "$TMPDIR1/test-mock-failing.sh"

exit_code=0
bash "$TMPDIR1/run-hook-tests.sh" > /dev/null 2>&1 || exit_code=$?

assert_ne "aggregator exits non-zero when test file fails" "0" "$exit_code"

cleanup_dir "$TMPDIR1"

# ============================================================
# Test 2: Aggregator exits zero when all test files pass
# ============================================================
echo "--- Test 2: aggregator exits zero when all tests pass ---"

TMPDIR2=$(make_isolated_dir)

# Write a mock passing test file
cat > "$TMPDIR2/test-mock-passing.sh" << 'EOF'
#!/usr/bin/env bash
PASS=1
FAIL=0
echo "Results: 1 passed, 0 failed"
exit 0
EOF
chmod +x "$TMPDIR2/test-mock-passing.sh"

exit_code=0
bash "$TMPDIR2/run-hook-tests.sh" > /dev/null 2>&1 || exit_code=$?

assert_eq "aggregator exits zero when all tests pass" "0" "$exit_code"

cleanup_dir "$TMPDIR2"

# ============================================================
# Test 3: Aggregator prints expected summary line
# ============================================================
echo "--- Test 3: aggregator prints Hook Tests summary line ---"

TMPDIR3=$(make_isolated_dir)

# Write a passing test file
cat > "$TMPDIR3/test-mock-passing.sh" << 'EOF'
#!/usr/bin/env bash
echo "Results: 2 passed, 0 failed"
exit 0
EOF
chmod +x "$TMPDIR3/test-mock-passing.sh"

output=$(bash "$TMPDIR3/run-hook-tests.sh" 2>&1 || true)
assert_contains "aggregator prints 'Hook Tests:' summary" "Hook Tests:" "$output"
assert_contains "aggregator prints 'PASSED:' in summary" "PASSED:" "$output"
assert_contains "aggregator prints 'FAILED:' in summary" "FAILED:" "$output"

cleanup_dir "$TMPDIR3"

# ============================================================
# Test 4: Aggregator counts pass/fail correctly across files
# ============================================================
echo "--- Test 4: aggregator accumulates counts across multiple test files ---"

TMPDIR4=$(make_isolated_dir)

cat > "$TMPDIR4/test-file-a.sh" << 'EOF'
#!/usr/bin/env bash
echo "Results: 3 passed, 0 failed"
exit 0
EOF
chmod +x "$TMPDIR4/test-file-a.sh"

cat > "$TMPDIR4/test-file-b.sh" << 'EOF'
#!/usr/bin/env bash
echo "Results: 2 passed, 1 failed"
exit 1
EOF
chmod +x "$TMPDIR4/test-file-b.sh"

output=$(bash "$TMPDIR4/run-hook-tests.sh" 2>&1 || true)

# Should show PASSED: 5  FAILED: 1
assert_contains "aggregator sums passed counts (5 total)" "PASSED: 5" "$output"
assert_contains "aggregator sums failed counts (1 total)" "FAILED: 1" "$output"

cleanup_dir "$TMPDIR4"

# ============================================================
# Test 5: Aggregator handles no test files (empty dir) gracefully
# ============================================================
echo "--- Test 5: aggregator handles empty dir (no test files) ---"

TMPDIR5=$(make_isolated_dir)

exit_code=0
bash "$TMPDIR5/run-hook-tests.sh" > /dev/null 2>&1 || exit_code=$?

assert_eq "aggregator exits zero with no test files" "0" "$exit_code"

cleanup_dir "$TMPDIR5"

# ============================================================
# Summary
# ============================================================
print_summary
