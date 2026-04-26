#!/usr/bin/env bash
# tests/scripts/test-bash-runner-discovery.sh
# Tests for plugins/dso/scripts/runners/bash-runner.sh discovery behavior.
#
# Verifies that the bash runner discovers test-*.sh files but excludes
# run-*-tests.sh aggregator scripts (which are suite orchestrators, not
# individual test items).
#
# Usage: bash tests/scripts/test-bash-runner-discovery.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
BASH_RUNNER="$DSO_PLUGIN_DIR/scripts/runners/bash-runner.sh"
TEST_BATCHED="$DSO_PLUGIN_DIR/scripts/test-batched.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-bash-runner-discovery.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Test 1: bash-runner.sh exists and is executable ──────────────────────────
echo "Test 1: bash-runner.sh exists and is executable"
if [ -f "$BASH_RUNNER" ] && [ -r "$BASH_RUNNER" ]; then
    echo "  PASS: bash-runner.sh exists"
    (( PASS++ ))
else
    echo "  FAIL: bash-runner.sh not found at $BASH_RUNNER" >&2
    (( FAIL++ ))
fi

# ── Test 2: Discovery does NOT include run-*-tests.sh files ──────────────────
echo "Test 2: test_discovery_excludes_aggregators — run-*-tests.sh not discovered"
test_discovery_excludes_aggregators() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")

    # Create test-*.sh files (should be discovered)
    cat > "$tmpdir/test-alpha.sh" << 'EOF'
#!/usr/bin/env bash
echo "PASSED: 1  FAILED: 0"
exit 0
EOF
    chmod +x "$tmpdir/test-alpha.sh"

    cat > "$tmpdir/test-beta.sh" << 'EOF'
#!/usr/bin/env bash
echo "PASSED: 1  FAILED: 0"
exit 0
EOF
    chmod +x "$tmpdir/test-beta.sh"

    # Create run-*-tests.sh aggregator (should NOT be discovered)
    cat > "$tmpdir/run-all-tests.sh" << 'EOF'
#!/usr/bin/env bash
echo "I am an aggregator — I should not be run as an individual test item"
exit 0
EOF
    chmod +x "$tmpdir/run-all-tests.sh"

    # Run batched runner and check output for the aggregator filename
    local output exit_code=0
    output=$(TEST_BATCHED_STATE_FILE="$tmpdir/state.json" \
        bash "$TEST_BATCHED" --timeout=30 --runner=bash --test-dir="$tmpdir" 2>&1) || exit_code=$?

    # The aggregator must NOT appear in the run output
    if [[ "$output" == *"run-all-tests.sh"* ]]; then
        echo "  DEBUG: aggregator was discovered and run" >&2
        return 1
    fi

    # test-alpha.sh and test-beta.sh must appear
    [[ "$output" == *"test-alpha.sh"* ]] || return 1
    [[ "$output" == *"test-beta.sh"* ]] || return 1
}
if test_discovery_excludes_aggregators; then
    echo "  PASS: run-*-tests.sh excluded from discovery"
    (( PASS++ ))
else
    echo "  FAIL: run-*-tests.sh was discovered as a test item" >&2
    (( FAIL++ ))
fi

# ── Test 3: Discovery DOES include test-*.sh files ───────────────────────────
echo "Test 3: test_discovery_includes_test_files — test-*.sh files discovered"
test_discovery_includes_test_files() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")

    cat > "$tmpdir/test-gamma.sh" << 'EOF'
#!/usr/bin/env bash
echo "PASSED: 1  FAILED: 0"
exit 0
EOF
    chmod +x "$tmpdir/test-gamma.sh"

    local output exit_code=0
    output=$(TEST_BATCHED_STATE_FILE="$tmpdir/state.json" \
        bash "$TEST_BATCHED" --timeout=30 --runner=bash --test-dir="$tmpdir" 2>&1) || exit_code=$?

    [[ "$output" == *"test-gamma.sh"* ]]
}
if test_discovery_includes_test_files; then
    echo "  PASS: test-*.sh files discovered"
    (( PASS++ ))
else
    echo "  FAIL: test-*.sh files not discovered" >&2
    (( FAIL++ ))
fi

# ── Test 4: Warning message does not mention run-*-tests.sh ──────────────────
echo "Test 4: test_warning_message_no_aggregator_mention — fallback warning updated"
test_warning_message_no_aggregator_mention() {
    # When no test files exist, the warning should only mention test-*.sh
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/empty-dir"

    local output exit_code=0
    output=$(TEST_BATCHED_STATE_FILE="$tmpdir/state.json" \
        bash "$TEST_BATCHED" --timeout=30 --runner=bash --test-dir="$tmpdir/empty-dir" 2>&1) || exit_code=$?

    # Warning should NOT mention run-*-tests.sh
    if [[ "$output" == *'run-*-tests.sh'* ]]; then
        return 1
    fi
    return 0
}
if test_warning_message_no_aggregator_mention; then
    echo "  PASS: warning message does not mention run-*-tests.sh"
    (( PASS++ ))
else
    echo "  FAIL: warning message still mentions run-*-tests.sh" >&2
    (( FAIL++ ))
fi

# ── Test 5: Multi-dir discovery (colon-separated --test-dir) ─────────────────
echo "Test 5: test_multi_dir_discovery — colon-separated --test-dir discovers files from all dirs"
test_multi_dir_discovery() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local suite_a="$tmpdir/suite_a" suite_b="$tmpdir/suite_b"
    mkdir -p "$suite_a" "$suite_b"

    cat > "$suite_a/test-alpha.sh" << 'EOF'
#!/usr/bin/env bash
echo "alpha pass"
exit 0
EOF
    chmod +x "$suite_a/test-alpha.sh"

    cat > "$suite_b/test-beta.sh" << 'EOF'
#!/usr/bin/env bash
echo "beta pass"
exit 0
EOF
    chmod +x "$suite_b/test-beta.sh"

    local output exit_code=0
    output=$(TEST_BATCHED_STATE_FILE="$tmpdir/state.json" \
        bash "$TEST_BATCHED" --timeout=30 --runner=bash \
        --test-dir="${suite_a}:${suite_b}" 2>&1) || exit_code=$?

    [ "$exit_code" -eq 0 ] || return 1
    [[ "$output" == *"test-alpha.sh"* ]] || return 1
    [[ "$output" == *"test-beta.sh"* ]] || return 1
    [[ "$output" == *"2/2 tests completed"* ]] || return 1
}
if test_multi_dir_discovery; then
    echo "  PASS: colon-separated --test-dir discovers files from all directories"
    (( PASS++ ))
else
    echo "  FAIL: multi-dir discovery did not find files from all directories" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
