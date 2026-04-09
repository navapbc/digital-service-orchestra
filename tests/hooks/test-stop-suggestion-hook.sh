#!/usr/bin/env bash
# tests/hooks/test-stop-suggestion-hook.sh
# Tests for hook_friction_suggestion_check in session-misc-functions.sh / stop.sh
#
# Tests assert that when tool-error-counter.json has counts exceeding thresholds,
# the stop hook calls suggestion-record. Uses DSO_SUGGESTION_RECORD_CMD to inject
# a mock command rather than relying on PATH-based resolution.
#
# All tests use an isolated $HOME (temp dir) so no real files are touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
STOP_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/stop.sh"
SESSION_MISC="$DSO_PLUGIN_DIR/hooks/lib/session-misc-functions.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# --- Test isolation ---
_REAL_HOME="$HOME"
TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude/logs"

# Shared suggestion config dir
_CONF_DIR=$(mktemp -d)
_CONF="$_CONF_DIR/dso-config.conf"
cat > "$_CONF" << 'EOF'
monitoring.tool_errors=true
suggestion.error_threshold=10
suggestion.timeout_threshold=3
EOF
export WORKFLOW_CONFIG_FILE="$_CONF"

COUNTER_FILE="$TEST_HOME/.claude/tool-error-counter.json"

trap 'export HOME="$_REAL_HOME"; unset WORKFLOW_CONFIG_FILE; unset DSO_SUGGESTION_RECORD_CMD; rm -rf "$TEST_HOME" "$_CONF_DIR"' EXIT

# ---------------------------------------------------------------------------
# Helper: create a mock suggestion-record command script.
# Sets _MOCK_CMD to the script path and _CALL_LOG to the call log path.
# ---------------------------------------------------------------------------
_setup_mock() {
    local tmpdir; tmpdir=$(mktemp -d)
    _CALL_LOG="$tmpdir/calls.log"
    _MOCK_CMD="$tmpdir/mock-suggest.sh"
    cat > "$_MOCK_CMD" << MOCK_EOF
#!/usr/bin/env bash
echo "\$@" >> "$_CALL_LOG"
exit 0
MOCK_EOF
    chmod +x "$_MOCK_CMD"
    export DSO_SUGGESTION_RECORD_CMD="$_MOCK_CMD"
}

_teardown_mock() {
    unset DSO_SUGGESTION_RECORD_CMD
    if [[ -n "${_MOCK_CMD:-}" ]]; then
        rm -rf "$(dirname "$_MOCK_CMD")"
        _MOCK_CMD=""
        _CALL_LOG=""
    fi
}

# ---------------------------------------------------------------------------
# Helper: source the hook function in a subprocess and call it.
# Uses CLAUDE_PLUGIN_ROOT to avoid sourcing from the installed cache.
# ---------------------------------------------------------------------------
_run_hook() {
    bash -c "
        export HOME='$TEST_HOME'
        export WORKFLOW_CONFIG_FILE='$_CONF'
        export CLAUDE_PLUGIN_ROOT='$DSO_PLUGIN_DIR'
        ${DSO_SUGGESTION_RECORD_CMD:+export DSO_SUGGESTION_RECORD_CMD='$DSO_SUGGESTION_RECORD_CMD'}
        source '$DSO_PLUGIN_DIR/hooks/lib/deps.sh' 2>/dev/null || true
        source '$SESSION_MISC'
        hook_friction_suggestion_check '{}'
    " 2>/dev/null
}

# ---------------------------------------------------------------------------
# test_stop_hook_no_crash_when_counter_missing
# When tool-error-counter.json is absent, the stop hook must not crash.
# ---------------------------------------------------------------------------
rm -f "$COUNTER_FILE"

_STOP_EXIT=0
bash "$STOP_DISPATCHER" >/dev/null 2>/dev/null || _STOP_EXIT=$?
assert_eq "test_stop_hook_no_crash_when_counter_missing" "0" "$_STOP_EXIT"

# ---------------------------------------------------------------------------
# test_stop_hook_no_suggestion_when_below_threshold
# Empty counter (no errors) — must not call suggestion-record.
# ---------------------------------------------------------------------------
echo '{"index":{},"errors":[]}' > "$COUNTER_FILE"
_setup_mock

_run_hook

_CALLED="no"
if [[ -f "$_CALL_LOG" ]]; then _CALLED="yes"; fi
assert_eq "test_stop_hook_no_suggestion_when_below_threshold" "no" "$_CALLED"

_teardown_mock
rm -f "$COUNTER_FILE"

# ---------------------------------------------------------------------------
# test_stop_hook_no_suggestion_when_errors_below_threshold
# Counter has errors but below both thresholds (error=9<10, timeout=2<3).
# Must NOT call suggestion-record.
# ---------------------------------------------------------------------------
python3 -c "
import json
data = {'index': {'edit_string_not_found': 7, 'command_not_found': 2}, 'errors': []}
print(json.dumps(data))
" > "$COUNTER_FILE"
_setup_mock

_run_hook

_CALLED="no"
if [[ -f "$_CALL_LOG" ]]; then _CALLED="yes"; fi
assert_eq "test_stop_hook_no_suggestion_when_errors_below_threshold" "no" "$_CALLED"

_teardown_mock
rm -f "$COUNTER_FILE"

# ---------------------------------------------------------------------------
# test_stop_hook_suggestion_when_error_count_exceeds_threshold
# Total error count >= suggestion.error_threshold (10). Must call suggestion-record.
# ---------------------------------------------------------------------------
python3 -c "
import json
data = {'index': {'timeout': 2, 'edit_string_not_found': 5, 'command_not_found': 4}, 'errors': []}
print(json.dumps(data))
" > "$COUNTER_FILE"
_setup_mock

_run_hook

_CALLED="no"
if [[ -f "$_CALL_LOG" ]]; then _CALLED="yes"; fi
assert_eq "test_stop_hook_suggestion_when_error_count_exceeds_threshold" "yes" "$_CALLED"

_teardown_mock
rm -f "$COUNTER_FILE"

# ---------------------------------------------------------------------------
# test_stop_hook_suggestion_when_timeout_count_exceeds_threshold
# Timeout count >= suggestion.timeout_threshold (3) even if total < error_threshold.
# Must call suggestion-record.
# ---------------------------------------------------------------------------
python3 -c "
import json
data = {'index': {'timeout': 4, 'command_not_found': 1}, 'errors': []}
print(json.dumps(data))
" > "$COUNTER_FILE"
_setup_mock

_run_hook

_CALLED="no"
if [[ -f "$_CALL_LOG" ]]; then _CALLED="yes"; fi
assert_eq "test_stop_hook_suggestion_when_timeout_count_exceeds_threshold" "yes" "$_CALLED"

_teardown_mock
rm -f "$COUNTER_FILE"

# ---------------------------------------------------------------------------
# test_stop_hook_no_suggestion_at_exactly_error_threshold
# Counter exactly at error threshold (total == 10, timeout == 0).
# The implementation uses -ge, so this SHOULD fire.
# Boundary test: verifies the >= comparison (fires at, not just above, threshold).
# ---------------------------------------------------------------------------
python3 -c "
import json
data = {'index': {'edit_string_not_found': 6, 'command_not_found': 4}, 'errors': []}
print(json.dumps(data))
" > "$COUNTER_FILE"
_setup_mock

_run_hook

_CALLED_AT_BOUNDARY="no"
if [[ -f "$_CALL_LOG" ]]; then _CALLED_AT_BOUNDARY="yes"; fi
assert_eq "test_stop_hook_no_suggestion_at_exactly_error_threshold: fires at exactly error_threshold (>=)" \
    "yes" "$_CALLED_AT_BOUNDARY"

_teardown_mock
rm -f "$COUNTER_FILE"

# ---------------------------------------------------------------------------
# test_stop_hook_suggestion_includes_source_stop_hook
# When suggestion-record is called, --source=stop-hook flag must be present.
# ---------------------------------------------------------------------------
python3 -c "
import json
data = {'index': {'timeout': 5, 'edit_string_not_found': 8}, 'errors': []}
print(json.dumps(data))
" > "$COUNTER_FILE"
_setup_mock

_run_hook

_HAS_SOURCE="no"
if [[ -f "$_CALL_LOG" ]] && grep -q -- '--source=stop-hook' "$_CALL_LOG" 2>/dev/null; then
    _HAS_SOURCE="yes"
fi
assert_eq "test_stop_hook_suggestion_includes_source_stop_hook" "yes" "$_HAS_SOURCE"

_teardown_mock
rm -f "$COUNTER_FILE"

# ---------------------------------------------------------------------------
# test_stop_hook_suggestion_includes_observation_flag
# When suggestion-record is called, --observation= named flag must be present.
# ---------------------------------------------------------------------------
python3 -c "
import json
data = {'index': {'timeout': 5, 'edit_string_not_found': 8}, 'errors': []}
print(json.dumps(data))
" > "$COUNTER_FILE"
_setup_mock

_run_hook

_HAS_OBS="no"
if [[ -f "$_CALL_LOG" ]] && grep -q -- '--observation=' "$_CALL_LOG" 2>/dev/null; then
    _HAS_OBS="yes"
fi
assert_eq "test_stop_hook_suggestion_includes_observation_flag" "yes" "$_HAS_OBS"

_teardown_mock
rm -f "$COUNTER_FILE"

# ---------------------------------------------------------------------------
# test_stop_hook_exits_zero_even_when_suggestion_record_fails
# Fail-open: even if DSO_SUGGESTION_RECORD_CMD exits non-zero, hook exits 0.
# ---------------------------------------------------------------------------
python3 -c "
import json
data = {'index': {'timeout': 5, 'edit_string_not_found': 8}, 'errors': []}
print(json.dumps(data))
" > "$COUNTER_FILE"

_FAIL_DIR=$(mktemp -d)
_FAIL_CMD="$_FAIL_DIR/fail-suggest.sh"
cat > "$_FAIL_CMD" << 'FAIL_EOF'
#!/usr/bin/env bash
exit 1
FAIL_EOF
chmod +x "$_FAIL_CMD"
export DSO_SUGGESTION_RECORD_CMD="$_FAIL_CMD"

_HOOK_EXIT=0
_run_hook || _HOOK_EXIT=$?
assert_eq "test_stop_hook_exits_zero_even_when_suggestion_record_fails" "0" "$_HOOK_EXIT"

unset DSO_SUGGESTION_RECORD_CMD
rm -rf "$_FAIL_DIR"
rm -f "$COUNTER_FILE"

# ---------------------------------------------------------------------------
# test_stop_hook_no_crash_when_counter_malformed_json
# Malformed JSON in counter file — must not crash, must exit 0.
# ---------------------------------------------------------------------------
echo "not valid json {{" > "$COUNTER_FILE"

_STOP_EXIT3=0
bash "$STOP_DISPATCHER" >/dev/null 2>/dev/null || _STOP_EXIT3=$?
assert_eq "test_stop_hook_no_crash_when_counter_malformed_json" "0" "$_STOP_EXIT3"

rm -f "$COUNTER_FILE"

print_summary
