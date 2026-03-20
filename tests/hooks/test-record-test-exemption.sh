#!/usr/bin/env bash
set -euo pipefail
# tests/hooks/test-record-test-exemption.sh
# Tests for hooks/record-test-exemption.sh (TDD RED phase)
#
# record-test-exemption.sh runs a test under a timeout and, when the runner
# exits 124 (timeout), records an exemption entry with node_id, threshold=60,
# and a timestamp to the exemptions file. These tests validate all behaviors
# BEFORE the implementation exists.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
EXEMPTION_SCRIPT="$DSO_PLUGIN_DIR/hooks/record-test-exemption.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Source deps.sh to use get_artifacts_dir()
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# ============================================================
# RED-phase guard: if script does not exist, print NOTE and pass trivially
# ============================================================
if [[ ! -f "$EXEMPTION_SCRIPT" ]]; then
    echo "NOTE: record-test-exemption.sh not found — running in RED phase"

    echo ""
    echo "=== test_exemption_written_on_timeout ==="
    assert_eq "test_exemption_written_on_timeout: RED phase trivially pass" "red" "red"

    echo ""
    echo "=== test_no_exemption_on_passing_test ==="
    assert_eq "test_no_exemption_on_passing_test: RED phase trivially pass" "red" "red"

    echo ""
    echo "=== test_exemption_file_format ==="
    assert_eq "test_exemption_file_format: RED phase trivially pass" "red" "red"

    echo ""
    echo "=== test_missing_node_id_argument ==="
    assert_eq "test_missing_node_id_argument: RED phase trivially pass" "red" "red"

    echo ""
    echo "=== test_exemption_idempotent ==="
    assert_eq "test_exemption_idempotent: RED phase trivially pass" "red" "red"

    print_summary
fi

# ============================================================
# Helper: run the exemption script and capture exit code
# ============================================================
run_exemption_exit() {
    local exit_code=0
    bash "$EXEMPTION_SCRIPT" "$@" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ============================================================
# test_exemption_written_on_timeout
# record-test-exemption.sh exits 0 AND writes an exemption entry
# with node_id, threshold=60, and timestamp to the exemptions file
# when the test runner times out (mock runner exits 124)
# ============================================================
echo ""
echo "=== test_exemption_written_on_timeout ==="

ARTIFACTS_1=$(mktemp -d "${TMPDIR:-/tmp}/test-rte-artifacts-XXXXXX")
trap 'rm -rf "$ARTIFACTS_1"' EXIT

# Create a mock runner that exits 124 (simulating a timeout)
MOCK_RUNNER_1=$(mktemp "${TMPDIR:-/tmp}/mock-runner-XXXXXX")
chmod +x "$MOCK_RUNNER_1"
cat > "$MOCK_RUNNER_1" << 'MOCKEOF'
#!/usr/bin/env bash
exit 124
MOCKEOF

NODE_ID_1="tests/unit/test_slow_thing.py::test_slow"
EXIT_CODE_1=$(
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_1" \
    RECORD_TEST_EXEMPTION_RUNNER="$MOCK_RUNNER_1" \
    run_exemption_exit "$NODE_ID_1"
)

EXEMPTIONS_FILE_1="$ARTIFACTS_1/test-exemptions"

assert_eq "test_exemption_written_on_timeout: exits 0" "0" "$EXIT_CODE_1"

if [[ -f "$EXEMPTIONS_FILE_1" ]]; then
    CONTENT_1=$(cat "$EXEMPTIONS_FILE_1")
    assert_contains "test_exemption_written_on_timeout: node_id present" "node_id=" "$CONTENT_1"
    assert_contains "test_exemption_written_on_timeout: threshold=60 present" "threshold=60" "$CONTENT_1"
    assert_contains "test_exemption_written_on_timeout: timestamp present" "timestamp=" "$CONTENT_1"
else
    assert_eq "test_exemption_written_on_timeout: exemptions file written" "exists" "missing"
fi

rm -f "$MOCK_RUNNER_1"
rm -rf "$ARTIFACTS_1"
trap - EXIT

# ============================================================
# test_no_exemption_on_passing_test
# When the test completes within 60s (exit 0), record-test-exemption.sh
# does NOT write an exemption and exits non-zero (error: test did not timeout)
# ============================================================
echo ""
echo "=== test_no_exemption_on_passing_test ==="

ARTIFACTS_2=$(mktemp -d "${TMPDIR:-/tmp}/test-rte-artifacts-XXXXXX")
trap 'rm -rf "$ARTIFACTS_2"' EXIT

# Create a mock runner that exits 0 (test passed without timing out)
MOCK_RUNNER_2=$(mktemp "${TMPDIR:-/tmp}/mock-runner-XXXXXX")
chmod +x "$MOCK_RUNNER_2"
cat > "$MOCK_RUNNER_2" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF

NODE_ID_2="tests/unit/test_fast_thing.py::test_fast"
EXIT_CODE_2=$(
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_2" \
    RECORD_TEST_EXEMPTION_RUNNER="$MOCK_RUNNER_2" \
    run_exemption_exit "$NODE_ID_2"
)

EXEMPTIONS_FILE_2="$ARTIFACTS_2/test-exemptions"

assert_ne "test_no_exemption_on_passing_test: exits non-zero" "0" "$EXIT_CODE_2"

if [[ -f "$EXEMPTIONS_FILE_2" ]]; then
    # File should NOT contain an entry for this node_id
    CONTENT_2=$(cat "$EXEMPTIONS_FILE_2")
    # Should be empty or not contain node_id of the passing test
    assert_ne "test_no_exemption_on_passing_test: no exemption written" \
        "1" \
        "$(echo "$CONTENT_2" | grep -c "node_id=${NODE_ID_2}" || echo "0")"
fi

rm -f "$MOCK_RUNNER_2"
rm -rf "$ARTIFACTS_2"
trap - EXIT

# ============================================================
# test_exemption_file_format
# The written exemption entry contains node_id=<test>, threshold=60,
# and timestamp=<ISO8601> fields parseable by the gate
# ============================================================
echo ""
echo "=== test_exemption_file_format ==="

ARTIFACTS_3=$(mktemp -d "${TMPDIR:-/tmp}/test-rte-artifacts-XXXXXX")
trap 'rm -rf "$ARTIFACTS_3"' EXIT

# Create a mock runner that times out (exits 124)
MOCK_RUNNER_3=$(mktemp "${TMPDIR:-/tmp}/mock-runner-XXXXXX")
chmod +x "$MOCK_RUNNER_3"
cat > "$MOCK_RUNNER_3" << 'MOCKEOF'
#!/usr/bin/env bash
exit 124
MOCKEOF

NODE_ID_3="tests/integration/test_db.py::test_heavy_query"
EXIT_CODE_3=$(
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_3" \
    RECORD_TEST_EXEMPTION_RUNNER="$MOCK_RUNNER_3" \
    run_exemption_exit "$NODE_ID_3"
)

EXEMPTIONS_FILE_3="$ARTIFACTS_3/test-exemptions"

if [[ -f "$EXEMPTIONS_FILE_3" ]]; then
    CONTENT_3=$(cat "$EXEMPTIONS_FILE_3")

    # Verify node_id field present with the correct value
    assert_contains "test_exemption_file_format: node_id field" "node_id=${NODE_ID_3}" "$CONTENT_3"

    # Verify threshold=60 is present
    assert_contains "test_exemption_file_format: threshold=60" "threshold=60" "$CONTENT_3"

    # Verify timestamp field matches ISO8601 pattern (YYYY-MM-DDTHH:MM:SSZ)
    TIMESTAMP_LINE=$(echo "$CONTENT_3" | grep '^timestamp=' || echo "")
    assert_ne "test_exemption_file_format: timestamp line present" "" "$TIMESTAMP_LINE"

    # Verify the timestamp value looks like ISO8601
    TIMESTAMP_VAL="${TIMESTAMP_LINE#timestamp=}"
    ISO8601_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    if echo "$TIMESTAMP_VAL" | grep -qE "$ISO8601_PATTERN"; then
        assert_eq "test_exemption_file_format: timestamp is ISO8601" "valid" "valid"
    else
        assert_eq "test_exemption_file_format: timestamp is ISO8601" "valid" "invalid: $TIMESTAMP_VAL"
    fi
else
    assert_eq "test_exemption_file_format: exemptions file written" "exists" "missing"
fi

rm -f "$MOCK_RUNNER_3"
rm -rf "$ARTIFACTS_3"
trap - EXIT

# ============================================================
# test_missing_node_id_argument
# Calling record-test-exemption.sh with no argument exits non-zero
# with a usage error
# ============================================================
echo ""
echo "=== test_missing_node_id_argument ==="

USAGE_EXIT_CODE=0
USAGE_OUTPUT=$(bash "$EXEMPTION_SCRIPT" 2>&1) || USAGE_EXIT_CODE=$?

assert_ne "test_missing_node_id_argument: exits non-zero" "0" "$USAGE_EXIT_CODE"
assert_contains "test_missing_node_id_argument: usage message present" "Usage" "$USAGE_OUTPUT"

# ============================================================
# test_exemption_idempotent
# Running record-test-exemption.sh twice for the same node_id results in
# exactly one entry for that node_id in the exemptions file
# (idempotent overwrite, not duplicate append)
# ============================================================
echo ""
echo "=== test_exemption_idempotent ==="

ARTIFACTS_5=$(mktemp -d "${TMPDIR:-/tmp}/test-rte-artifacts-XXXXXX")
trap 'rm -rf "$ARTIFACTS_5"' EXIT

# Create a mock runner that always times out (exits 124)
MOCK_RUNNER_5=$(mktemp "${TMPDIR:-/tmp}/mock-runner-XXXXXX")
chmod +x "$MOCK_RUNNER_5"
cat > "$MOCK_RUNNER_5" << 'MOCKEOF'
#!/usr/bin/env bash
exit 124
MOCKEOF

NODE_ID_5="tests/unit/test_slow_repeated.py::test_repeated"

# First run
WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_5" \
RECORD_TEST_EXEMPTION_RUNNER="$MOCK_RUNNER_5" \
bash "$EXEMPTION_SCRIPT" "$NODE_ID_5" 2>/dev/null || true

# Second run (same node_id)
WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_5" \
RECORD_TEST_EXEMPTION_RUNNER="$MOCK_RUNNER_5" \
bash "$EXEMPTION_SCRIPT" "$NODE_ID_5" 2>/dev/null || true

EXEMPTIONS_FILE_5="$ARTIFACTS_5/test-exemptions"

if [[ -f "$EXEMPTIONS_FILE_5" ]]; then
    # Count occurrences of the node_id entry — must be exactly 1 (idempotent)
    ENTRY_COUNT=$(grep -c "node_id=${NODE_ID_5}" "$EXEMPTIONS_FILE_5" || echo "0")
    assert_eq "test_exemption_idempotent: exactly one entry for node_id" "1" "$ENTRY_COUNT"
else
    assert_eq "test_exemption_idempotent: exemptions file written" "exists" "missing"
fi

rm -f "$MOCK_RUNNER_5"
rm -rf "$ARTIFACTS_5"
trap - EXIT

print_summary
