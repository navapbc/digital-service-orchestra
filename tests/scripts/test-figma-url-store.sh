#!/usr/bin/env bash
# tests/scripts/test-figma-url-store.sh
# Behavioral tests for plugins/dso/scripts/figma-url-store.sh
#
# Tests: FUS-1 through FUS-4
#
# Usage: bash tests/scripts/test-figma-url-store.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/figma-url-store.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-figma-url-store.sh ==="

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Script existence check
if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: figma-url-store.sh not found at $SCRIPT" >&2
    (( ++FAIL ))
    print_summary
    exit 1
fi

# =============================================================================
# FUS-1: Valid /design/ URL → file key extracted and stored as ticket comment
# =============================================================================
echo ""
echo "--- test_fus_1_design_url_stores_file_key ---"
_snapshot_fail

TICKET_CALLS1="$TMPDIR_TEST/fus1_ticket_calls.txt"
cat > "$TMPDIR_TEST/mock-ticket1" <<MOCKTICKET
#!/usr/bin/env bash
echo "\$@" >> "$TICKET_CALLS1"
exit 0
MOCKTICKET
chmod +x "$TMPDIR_TEST/mock-ticket1"

result1=$(TICKET_CMD="$TMPDIR_TEST/mock-ticket1" PROJECT_ROOT="$PLUGIN_ROOT" \
    bash "$SCRIPT" "test-1234" "https://www.figma.com/design/abc123XYZ/My-Design" 2>&1)
exit_code1=$?

assert_eq "FUS-1: exit code should be 0" "0" "$exit_code1"
assert_contains "FUS-1: output should contain file key" "abc123XYZ" "$result1"
ticket_calls1=$(cat "$TICKET_CALLS1" 2>/dev/null || echo "")
assert_contains "FUS-1: ticket comment should contain file key" "figma_file_key: abc123XYZ" "$ticket_calls1"

assert_pass_if_clean "test_fus_1_design_url_stores_file_key"

# =============================================================================
# FUS-2: Valid /file/ URL → file key extracted and stored
# =============================================================================
echo ""
echo "--- test_fus_2_file_url_stores_file_key ---"
_snapshot_fail

TICKET_CALLS2="$TMPDIR_TEST/fus2_ticket_calls.txt"
cat > "$TMPDIR_TEST/mock-ticket2" <<MOCKTICKET
#!/usr/bin/env bash
echo "\$@" >> "$TICKET_CALLS2"
exit 0
MOCKTICKET
chmod +x "$TMPDIR_TEST/mock-ticket2"

result2=$(TICKET_CMD="$TMPDIR_TEST/mock-ticket2" PROJECT_ROOT="$PLUGIN_ROOT" \
    bash "$SCRIPT" "test-5678" "https://www.figma.com/file/def456ABC/Another-Design" 2>&1)
exit_code2=$?

assert_eq "FUS-2: exit code should be 0" "0" "$exit_code2"
ticket_calls2=$(cat "$TICKET_CALLS2" 2>/dev/null || echo "")
assert_contains "FUS-2: ticket comment should contain file key" "figma_file_key: def456ABC" "$ticket_calls2"

assert_pass_if_clean "test_fus_2_file_url_stores_file_key"

# =============================================================================
# FUS-3: Missing arguments → exit 1 with usage message
# =============================================================================
echo ""
echo "--- test_fus_3_missing_args_exits_1 ---"
_snapshot_fail

err3=$(bash "$SCRIPT" 2>&1); exit_code3=$?; true

assert_eq "FUS-3: exit code should be 1 when no args" "1" "$exit_code3"
assert_contains "FUS-3: should print Usage on missing args" "Usage:" "$err3"

assert_pass_if_clean "test_fus_3_missing_args_exits_1"

# =============================================================================
# FUS-4: Invalid URL → exit 1 with error message
# =============================================================================
echo ""
echo "--- test_fus_4_invalid_url_exits_1 ---"
_snapshot_fail

err4=$(bash "$SCRIPT" "test-1234" "https://example.com/not-figma" 2>&1); exit_code4=$?; true

assert_eq "FUS-4: exit code should be 1 for non-Figma URL" "1" "$exit_code4"
assert_contains "FUS-4: should print error for invalid URL" "Error" "$err4"

assert_pass_if_clean "test_fus_4_invalid_url_exits_1"

print_summary
