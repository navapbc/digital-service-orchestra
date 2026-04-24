#!/usr/bin/env bash
# tests/scripts/test-ticket-classify.sh
# RED integration tests for 'ticket classify' subcommand routing through the dispatcher.
#
# Tests verify that the dispatcher correctly routes 'ticket classify' to classify-task.sh
# and that the output is a JSON array with required classification fields.
#
# RED STATE: Tests currently fail because the dispatcher does not have a 'classify'
# case. They will pass (GREEN) after ticket-lib-api.sh ticket_classify() and the
# dispatcher case are implemented.
#
# RED MARKER:
# tests/scripts/test-ticket-classify.sh [test_classify_routes_through_dispatcher]
#
# Usage: bash tests/scripts/test-ticket-classify.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test assertions (( FAIL++ )) return non-zero by design;
# -e would abort the script on the first failing test instead of collecting all results.
# REVIEW-DEFENSE: PASS/FAIL counters initialized by run_test.sh `: "${PASS:=0}"` (line 14).
# All test files in this suite use the same sourced-library initialization pattern.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCHER="$PLUGIN_ROOT/plugins/dso/scripts/ticket"

source "$SCRIPT_DIR/../lib/run_test.sh"

# ── Cleanup ───────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-ticket-classify.sh ==="

# ── Fixture helpers ───────────────────────────────────────────────────────────

# make_ticket_mock — creates a mock ticket command for TICKET_CMD injection.
# The mock responds to 'ticket show t1/t2' and 'ticket list'.
make_ticket_mock() {
    local mock_dir
    mock_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$mock_dir")
    local mock_script="$mock_dir/ticket"
    cat > "$mock_script" << 'MOCK_TICKET_EOF'
#!/usr/bin/env bash
SUBCMD="${1:-}"
TICKET_ID="${2:-}"
case "$SUBCMD" in
    show)
        case "$TICKET_ID" in
            t1) echo '{"ticket_id":"t1","title":"Implement authentication middleware","ticket_type":"task","status":"open","priority":2,"tags":[],"description":"Add JWT auth middleware","notes":"","deps":[]}' ; exit 0 ;;
            t2) echo '{"ticket_id":"t2","title":"Write unit tests for parser","ticket_type":"task","status":"open","priority":3,"tags":[],"description":"Unit tests for the parser module","notes":"","deps":[]}' ; exit 0 ;;
            *) exit 1 ;;
        esac ;;
    list) echo '[]' ; exit 0 ;;
    *) exit 0 ;;
esac
MOCK_TICKET_EOF
    chmod +x "$mock_script"
    echo "$mock_script"
}

# ── Test 1: Dispatcher exists and is executable ───────────────────────────────
echo "Test 1: Dispatcher exists and is executable"
if [[ -x "$DISPATCHER" ]]; then
    echo "  PASS: dispatcher is executable"
    (( PASS++ ))
else
    echo "  FAIL: $DISPATCHER is not executable or does not exist" >&2
    (( FAIL++ ))
fi

# ── Tests 2-7: Routing and output contract (RED zone) ────────────────────────
# All tests from here through end require the classify case in the dispatcher.
# RED MARKER function — parser uses this as the zone boundary.
test_classify_routes_through_dispatcher() {
    local _mock _output _exit _valid

    # Test 2: 'ticket classify' is recognized (not unknown subcommand)
    echo "Test 2: 'ticket classify' routes through dispatcher (not unknown subcommand)"
    _mock=$(make_ticket_mock)
    _exit=0
    _output=$(TICKET_CMD="$_mock" "$DISPATCHER" classify t1 2>&1) || _exit=$?

    if [[ "${_output,,}" =~ unknown.*subcommand|unrecognized.*subcommand ]]; then
        echo "  FAIL: dispatcher does not recognize 'classify' subcommand (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    elif [[ $_exit -ge 5 ]]; then
        echo "  FAIL: dispatcher returned crash-level exit code $_exit for 'classify'" >&2
        (( FAIL++ ))
    else
        echo "  PASS: 'classify' routed correctly through dispatcher (exit $_exit)"
        (( PASS++ ))
    fi

    # Test 3: Single ID produces valid JSON array
    echo "Test 3: Single ticket ID produces valid JSON array"
    _mock=$(make_ticket_mock)
    _exit=0
    _output=$(TICKET_CMD="$_mock" "$DISPATCHER" classify t1 2>/dev/null) || _exit=$?
    _valid=0
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
assert isinstance(data, list) and len(data) >= 1
" "$_output" 2>/dev/null || _valid=$?

    if [[ $_valid -eq 0 ]]; then
        echo "  PASS: single ID produces valid JSON array"
        (( PASS++ ))
    else
        echo "  FAIL: single ID did not produce valid JSON array (RED — expected before GREEN)" >&2
        (( FAIL++ ))
    fi

    # Test 4: Classification object has required fields
    echo "Test 4: Classification object has required fields (id, class, subagent, model)"
    _mock=$(make_ticket_mock)
    _exit=0
    _output=$(TICKET_CMD="$_mock" "$DISPATCHER" classify t1 2>/dev/null) || _exit=$?
    _valid=0
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
obj = data[0]
missing = [f for f in ['id','class','subagent','model'] if f not in obj]
if missing: raise ValueError(f'Missing: {missing}')
" "$_output" 2>/dev/null || _valid=$?

    if [[ $_valid -eq 0 ]]; then
        echo "  PASS: classification object has required fields"
        (( PASS++ ))
    else
        echo "  FAIL: classification object missing required fields (RED — expected before GREEN)" >&2
        (( FAIL++ ))
    fi

    # Test 5: Multiple IDs produce array with matching length
    echo "Test 5: Multiple ticket IDs produce array with matching length"
    _mock=$(make_ticket_mock)
    _exit=0
    _output=$(TICKET_CMD="$_mock" "$DISPATCHER" classify t1 t2 2>/dev/null) || _exit=$?
    _valid=0
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
assert isinstance(data, list) and len(data) == 2, f'expected 2, got {len(data)}'
" "$_output" 2>/dev/null || _valid=$?

    if [[ $_valid -eq 0 ]]; then
        echo "  PASS: two IDs produced array of length 2"
        (( PASS++ ))
    else
        echo "  FAIL: multiple IDs did not produce correct array length (RED — expected before GREEN)" >&2
        (( FAIL++ ))
    fi

    # Test 6: Result id field matches input ticket ID
    echo "Test 6: Result id field matches input ticket ID"
    _mock=$(make_ticket_mock)
    _exit=0
    _output=$(TICKET_CMD="$_mock" "$DISPATCHER" classify t1 2>/dev/null) || _exit=$?
    _valid=0
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
assert data[0]['id'] == 't1', f'id mismatch: expected t1, got {data[0][\"id\"]}'
" "$_output" 2>/dev/null || _valid=$?

    if [[ $_valid -eq 0 ]]; then
        echo "  PASS: result id field matches input ticket ID"
        (( PASS++ ))
    else
        echo "  FAIL: result id field does not match (RED — expected before GREEN)" >&2
        (( FAIL++ ))
    fi

    # Test 7: No args — exits non-zero or returns empty array
    echo "Test 7: No ticket IDs handled gracefully"
    _mock=$(make_ticket_mock)
    _exit=0
    _output=$(TICKET_CMD="$_mock" "$DISPATCHER" classify 2>&1) || _exit=$?

    if [[ $_exit -ne 0 ]] || [[ "${_output,,}" =~ usage|error|required ]]; then
        echo "  PASS: classify with no args handled gracefully (exit $_exit)"
        (( PASS++ ))
    else
        _empty_ok=0
        python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d==[]" "$_output" 2>/dev/null && _empty_ok=1
        if [[ $_empty_ok -eq 1 ]]; then
            echo "  PASS: classify with no args returns empty array"
            (( PASS++ ))
        else
            echo "  FAIL: classify with no args produced unexpected output (exit $_exit)" >&2
            (( FAIL++ ))
        fi
    fi
}

# Run the RED zone tests
test_classify_routes_through_dispatcher

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
