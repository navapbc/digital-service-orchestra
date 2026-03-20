#!/usr/bin/env bash
# tests/scripts/test-end-session-error-sweep.sh
# Tests for sweep_tool_errors() monitoring.tool_errors guard in plugins/dso/skills/end-session/error-sweep.sh
#
# Validates:
#   - sweep_tool_errors returns 0 and creates no tickets when monitoring.tool_errors is absent
#   - sweep_tool_errors returns 0 and creates no tickets when monitoring.tool_errors=false
#   - sweep_tool_errors triggers ticket creation when monitoring.tool_errors=true and threshold is reached
#
# Usage: bash tests/scripts/test-end-session-error-sweep.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SWEEP_SCRIPT="$PLUGIN_ROOT/plugins/dso/skills/end-session/error-sweep.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-end-session-error-sweep.sh ==="

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
# sweep_tool_errors should trigger ticket creation (call `tk create`).
test_sweep_enabled_when_flag_true() {
    local tmpdir; tmpdir=$(mktemp -d)
    local tmpconf="$tmpdir/dso-config.conf"
    local tmp_home="$tmpdir/home"
    mkdir -p "$tmp_home/.claude"

    # Config with monitoring.tool_errors=true
    echo "monitoring.tool_errors=true" > "$tmpconf"

    # Counter file with TOOL_USE_BLOCKED at threshold (50), no errors array entries
    echo '{"index":{"TOOL_USE_BLOCKED":50},"errors":[]}' > "$tmp_home/.claude/tool-error-counter.json"

    # Mock tk to track calls — also mock tk list to return empty (no existing open bugs)
    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    local tk_log="$tmpdir/tk.log"
    # tk list returns empty; tk create logs its args
    cat > "$mock_bin/tk" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${TK_LOG_FILE}"
if [[ "${1:-}" == "list" ]]; then
    echo ""
fi
MOCK
    chmod +x "$mock_bin/tk"

    # Run sweep_tool_errors in a subshell with controlled env
    TK_LOG_FILE="$tk_log" WORKFLOW_CONFIG_FILE="$tmpconf" HOME="$tmp_home" PATH="$mock_bin:$PATH" bash -c '
        source "'"$SWEEP_SCRIPT"'"
        sweep_tool_errors
    ' 2>/dev/null
    local exit_code=$?

    local ticket_created="no"
    [[ -f "$tk_log" ]] && grep -q "create" "$tk_log" && ticket_created="yes"

    rm -rf "$tmpdir"

    # After guard: ticket IS created when flag is true and threshold is reached
    # Before guard (RED state for the other two tests): this test also fails because
    # the guard doesn't exist yet — sweep always runs regardless of config flag,
    # so in the current (no-guard) state this test PASSES (ticket is always created).
    # This assertion verifies the enabled path still works after the guard is added.
    assert_eq "test_sweep_enabled_when_flag_true: ticket created" "yes" "$ticket_created"
    assert_eq "test_sweep_enabled_when_flag_true: exits 0" "0" "$exit_code"
}

# Run all tests
test_sweep_disabled_when_flag_absent
test_sweep_disabled_when_flag_false
test_sweep_enabled_when_flag_true

print_summary
