#!/usr/bin/env bash
# tests/scripts/test-error-sweep-config-gate.sh
# Tests for sweep_tool_errors() monitoring.tool_errors guard in plugins/dso/scripts/end-session/error-sweep.sh
#
# Validates:
#   - sweep_tool_errors returns 0 and creates no tickets when monitoring.tool_errors is absent
#   - sweep_tool_errors returns 0 and creates no tickets when monitoring.tool_errors=false
#   - sweep_tool_errors triggers ticket creation when monitoring.tool_errors=true and threshold is reached
#
# Usage: bash tests/scripts/test-error-sweep-config-gate.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWEEP_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/end-session/error-sweep.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-error-sweep-config-gate.sh ==="

# ── test_sweep_disabled_when_flag_absent ─────────────────────────────────────
# When monitoring.tool_errors is absent from config, sweep_tool_errors should
# return 0 and NOT create any ticket — even when counter file is at threshold.
test_sweep_disabled_when_flag_absent() {
    local tmpdir; tmpdir=$(mktemp -d)
    local tmpconf="$tmpdir/dso-config.conf"
    local tmp_home="$tmpdir/home"
    mkdir -p "$tmp_home/.claude"

    # Config with no monitoring.tool_errors key
    echo "# empty config — no monitoring.tool_errors" > "$tmpconf"

    # Counter file with TOOL_USE_BLOCKED at threshold (50)
    echo '{"index":{"TOOL_USE_BLOCKED":50},"errors":[]}' > "$tmp_home/.claude/tool-error-counter.json"

    # Mock tk to track calls
    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    local tk_log="$tmpdir/tk.log"
    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$tk_log" > "$mock_bin/tk"
    chmod +x "$mock_bin/tk"

    # Run sweep_tool_errors in a subshell with controlled env
    WORKFLOW_CONFIG_FILE="$tmpconf" HOME="$tmp_home" PATH="$mock_bin:$PATH" bash -c '
        source "'"$SWEEP_SCRIPT"'"
        sweep_tool_errors
    ' 2>/dev/null
    local exit_code=$?

    local ticket_created="no"
    [[ -f "$tk_log" ]] && grep -q "create" "$tk_log" && ticket_created="yes"

    rm -rf "$tmpdir"

    # After guard: no ticket created when flag absent
    # Before guard (RED state): ticket IS created → this assert fails
    assert_eq "test_sweep_disabled_when_flag_absent: no ticket created" "no" "$ticket_created"
    assert_eq "test_sweep_disabled_when_flag_absent: exits 0" "0" "$exit_code"
}

# ── test_sweep_disabled_when_flag_false ──────────────────────────────────────
# When monitoring.tool_errors=false, sweep_tool_errors should return 0 and
# NOT create any ticket — even when counter file is at threshold.
test_sweep_disabled_when_flag_false() {
    local tmpdir; tmpdir=$(mktemp -d)
    local tmpconf="$tmpdir/dso-config.conf"
    local tmp_home="$tmpdir/home"
    mkdir -p "$tmp_home/.claude"

    # Config with monitoring.tool_errors explicitly false
    echo "monitoring.tool_errors=false" > "$tmpconf"

    # Counter file with TOOL_USE_BLOCKED at threshold (50)
    echo '{"index":{"TOOL_USE_BLOCKED":50},"errors":[]}' > "$tmp_home/.claude/tool-error-counter.json"

    # Mock tk to track calls
    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    local tk_log="$tmpdir/tk.log"
    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$tk_log" > "$mock_bin/tk"
    chmod +x "$mock_bin/tk"

    # Run sweep_tool_errors in a subshell with controlled env
    WORKFLOW_CONFIG_FILE="$tmpconf" HOME="$tmp_home" PATH="$mock_bin:$PATH" bash -c '
        source "'"$SWEEP_SCRIPT"'"
        sweep_tool_errors
    ' 2>/dev/null
    local exit_code=$?

    local ticket_created="no"
    [[ -f "$tk_log" ]] && grep -q "create" "$tk_log" && ticket_created="yes"

    rm -rf "$tmpdir"

    # After guard: no ticket created when flag is false
    # Before guard (RED state): ticket IS created → this assert fails
    assert_eq "test_sweep_disabled_when_flag_false: no ticket created" "no" "$ticket_created"
    assert_eq "test_sweep_disabled_when_flag_false: exits 0" "0" "$exit_code"
}

# ── test_sweep_enabled_when_flag_true ────────────────────────────────────────
# When monitoring.tool_errors=true and counter file has TOOL_USE_BLOCKED >= 50,
# sweep_tool_errors should trigger ticket creation via the ticket CLI.
test_sweep_enabled_when_flag_true() {
    local tmpdir; tmpdir=$(mktemp -d)
    local tmpconf="$tmpdir/dso-config.conf"
    local tmp_home="$tmpdir/home"
    mkdir -p "$tmp_home/.claude"

    # Config with monitoring.tool_errors=true
    echo "monitoring.tool_errors=true" > "$tmpconf"

    # Counter file with TOOL_USE_BLOCKED at threshold (50), no errors array entries
    echo '{"index":{"TOOL_USE_BLOCKED":50},"errors":[]}' > "$tmp_home/.claude/tool-error-counter.json"

    # Mock ticket CLI to track calls — list returns empty JSON array (no existing open bugs);
    # create logs its args and returns a fake ticket ID.
    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    local ticket_log="$tmpdir/ticket.log"
    cat > "$mock_bin/ticket-mock" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${TICKET_LOG_FILE}"
if [[ "${1:-}" == "list" ]]; then
    echo "[]"
elif [[ "${1:-}" == "create" ]]; then
    echo "mock-1234"
fi
MOCK
    chmod +x "$mock_bin/ticket-mock"

    # Run sweep_tool_errors in a subshell with controlled env; TICKET_CMD points to mock
    TICKET_LOG_FILE="$ticket_log" TICKET_CMD="$mock_bin/ticket-mock" WORKFLOW_CONFIG_FILE="$tmpconf" HOME="$tmp_home" bash -c '
        source "'"$SWEEP_SCRIPT"'"
        sweep_tool_errors
    ' 2>/dev/null
    local exit_code=$?

    local ticket_created="no"
    [[ -f "$ticket_log" ]] && grep -q "create" "$ticket_log" && ticket_created="yes"

    rm -rf "$tmpdir"

    # After guard: ticket IS created when flag is true and threshold is reached.
    # This assertion verifies the enabled path still works after migration to ticket CLI.
    assert_eq "test_sweep_enabled_when_flag_true: ticket created" "yes" "$ticket_created"
    assert_eq "test_sweep_enabled_when_flag_true: exits 0" "0" "$exit_code"
}

# ── test_error_sweep_no_tk_list_call ─────────────────────────────────────────
# After v2 removal, error-sweep.sh should NOT call `tk list` directly.
# The script should use the ticket CLI (ticket list) instead.
# RED: currently the script calls `tk list --type bug --status open` → grep exits 0 → assert fails.
test_error_sweep_no_tk_list_call() {
    local exit_code
    grep -q 'tk list' "$SWEEP_SCRIPT" 2>/dev/null
    exit_code=$?
    # We expect grep to find NO match (exit non-zero) after v2 removal.
    assert_eq "test_error_sweep_no_tk_list_call: no 'tk list' call in error-sweep.sh" "1" "$exit_code"
}

# ── test_error_sweep_no_tk_create_call ───────────────────────────────────────
# After v2 removal, error-sweep.sh should NOT call `tk create` directly.
# The script should use the ticket CLI (ticket create) instead.
# RED: currently the script calls `tk create "$ticket_title" ...` → grep exits 0 → assert fails.
test_error_sweep_no_tk_create_call() {
    local exit_code
    grep -q 'tk create' "$SWEEP_SCRIPT" 2>/dev/null
    exit_code=$?
    # We expect grep to find NO match (exit non-zero) after v2 removal.
    assert_eq "test_error_sweep_no_tk_create_call: no 'tk create' call in error-sweep.sh" "1" "$exit_code"
}

# ── test_error_sweep_uses_ticket_cli ─────────────────────────────────────────
# After v2 removal, error-sweep.sh should use the ticket CLI commands
# (ticket list or ticket create) rather than the tk binary.
# RED: currently uses `tk list`/`tk create` → grep for ticket list|ticket create exits non-zero → assert fails.
test_error_sweep_uses_ticket_cli() {
    local exit_code
    grep -qE 'ticket list|ticket create' "$SWEEP_SCRIPT" 2>/dev/null
    exit_code=$?
    # We expect grep to find a match (exit 0) after implementation.
    assert_eq "test_error_sweep_uses_ticket_cli: error-sweep.sh uses ticket list or ticket create" "0" "$exit_code"
}

# Run all tests
test_sweep_disabled_when_flag_absent
test_sweep_disabled_when_flag_false
test_sweep_enabled_when_flag_true
test_error_sweep_no_tk_list_call
test_error_sweep_no_tk_create_call
test_error_sweep_uses_ticket_cli

print_summary
