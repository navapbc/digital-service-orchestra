#!/usr/bin/env bash
# tests/hooks/test-brainstorm-gate-hook.sh
# Tests for hook_brainstorm_gate (in session-misc-functions.sh) and
# the pre-enterplanmode.sh dispatcher.
#
# hook_brainstorm_gate is a PreToolUse hook (EnterPlanMode matcher) that
# blocks EnterPlanMode if no brainstorm sentinel has been recorded for this
# session (i.e., /dso:brainstorm has not been run for the current epic).
#
# These tests MUST FAIL (RED) because hook_brainstorm_gate and
# pre-enterplanmode.sh do not yet exist.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/pre-enterplanmode.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

ARTIFACTS_DIR=$(get_artifacts_dir)

# ---------------------------------------------------------------------------
# Helper: call hook_brainstorm_gate by sourcing session-misc-functions.sh
# ---------------------------------------------------------------------------
run_hook_fn() {
    local input="$1"
    local exit_code=0
    (
        # Source libs needed by hook function
        source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"
        source "$DSO_PLUGIN_DIR/hooks/lib/session-misc-functions.sh"
        hook_brainstorm_gate "$input"
    ) 2>/dev/null
    exit_code=$?
    echo "$exit_code"
}

# ---------------------------------------------------------------------------
# Helper: pipe JSON to pre-enterplanmode.sh dispatcher
# ---------------------------------------------------------------------------
run_dispatcher() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$DISPATCHER" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ---------------------------------------------------------------------------
# test_brainstorm_gate_sentinel_absent_blocks
# No sentinel file → hook_brainstorm_gate must return exit 2 (block)
# ---------------------------------------------------------------------------
SESSION_ID="test-session-no-sentinel-$$"
SENTINEL_FILE="$ARTIFACTS_DIR/brainstorm-sentinel-${SESSION_ID}"
# Ensure no leftover sentinel from prior runs
rm -f "$SENTINEL_FILE"

INPUT_NO_SENTINEL="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"${SESSION_ID}\"}"
EXIT_CODE=$(run_hook_fn "$INPUT_NO_SENTINEL")
assert_eq "test_brainstorm_gate_sentinel_absent_blocks" "2" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_sentinel_present_allows
# Sentinel file exists for the session → hook must return exit 0 (allow)
# ---------------------------------------------------------------------------
SESSION_ID_WITH="test-session-with-sentinel-$$"
SENTINEL_FILE_WITH="$ARTIFACTS_DIR/brainstorm-sentinel-${SESSION_ID_WITH}"
mkdir -p "$ARTIFACTS_DIR"
echo "completed" > "$SENTINEL_FILE_WITH"

INPUT_WITH_SENTINEL="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"${SESSION_ID_WITH}\"}"
EXIT_CODE=$(run_hook_fn "$INPUT_WITH_SENTINEL")
assert_eq "test_brainstorm_gate_sentinel_present_allows" "0" "$EXIT_CODE"

# Cleanup
rm -f "$SENTINEL_FILE_WITH"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_config_disabled_allows
# Config brainstorm.enforce_entry_gate=false → hook returns exit 0 even without sentinel
# ---------------------------------------------------------------------------
TMP_CONFIG_DIR=$(mktemp -d)
TMP_CONFIG_FILE="$TMP_CONFIG_DIR/dso-config.conf"
cat > "$TMP_CONFIG_FILE" <<'CONF'
brainstorm.enforce_entry_gate=false
CONF

SESSION_ID_DISABLED="test-session-gate-disabled-$$"
SENTINEL_FILE_DISABLED="$ARTIFACTS_DIR/brainstorm-sentinel-${SESSION_ID_DISABLED}"
rm -f "$SENTINEL_FILE_DISABLED"

INPUT_GATE_DISABLED="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"${SESSION_ID_DISABLED}\"}"
EXIT_CODE=$(
    WORKFLOW_CONFIG_FILE="$TMP_CONFIG_FILE" \
    run_hook_fn "$INPUT_GATE_DISABLED"
)
assert_eq "test_brainstorm_gate_config_disabled_allows" "0" "$EXIT_CODE"

# Cleanup
rm -rf "$TMP_CONFIG_DIR"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_non_enterplanmode_passthrough
# Non-EnterPlanMode tool calls should pass through (exit 0)
# ---------------------------------------------------------------------------
SESSION_ID_PASS="test-session-passthrough-$$"
rm -f "$ARTIFACTS_DIR/brainstorm-sentinel-${SESSION_ID_PASS}"

INPUT_OTHER="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"session_id\":\"${SESSION_ID_PASS}\"}"
EXIT_CODE=$(run_hook_fn "$INPUT_OTHER")
assert_eq "test_brainstorm_gate_non_enterplanmode_passthrough" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_dispatcher_blocks_without_sentinel (functional dispatcher test)
# Pipe EnterPlanMode JSON to pre-enterplanmode.sh dispatcher → must block (exit 2)
# ---------------------------------------------------------------------------
SESSION_ID_DISP="test-session-dispatcher-block-$$"
rm -f "$ARTIFACTS_DIR/brainstorm-sentinel-${SESSION_ID_DISP}"

INPUT_DISP_BLOCK="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"${SESSION_ID_DISP}\"}"
EXIT_CODE=$(run_dispatcher "$INPUT_DISP_BLOCK")
assert_eq "test_brainstorm_gate_dispatcher_blocks_without_sentinel" "2" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_dispatcher_allows_with_sentinel (functional dispatcher test)
# Pipe EnterPlanMode JSON to pre-enterplanmode.sh dispatcher with sentinel present → allow (exit 0)
# ---------------------------------------------------------------------------
SESSION_ID_DISP_ALLOW="test-session-dispatcher-allow-$$"
SENTINEL_FILE_DISP="$ARTIFACTS_DIR/brainstorm-sentinel-${SESSION_ID_DISP_ALLOW}"
mkdir -p "$ARTIFACTS_DIR"
echo "completed" > "$SENTINEL_FILE_DISP"

INPUT_DISP_ALLOW="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"${SESSION_ID_DISP_ALLOW}\"}"
EXIT_CODE=$(run_dispatcher "$INPUT_DISP_ALLOW")
assert_eq "test_brainstorm_gate_dispatcher_allows_with_sentinel" "0" "$EXIT_CODE"

# Cleanup
rm -f "$SENTINEL_FILE_DISP"

print_summary
