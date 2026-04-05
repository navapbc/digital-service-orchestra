#!/usr/bin/env bash
# tests/hooks/test-brainstorm-gate-hook.sh
# Tests for hook_brainstorm_gate (in session-misc-functions.sh) and
# the pre-enterplanmode.sh dispatcher.
#
# hook_brainstorm_gate is a PreToolUse hook (EnterPlanMode matcher) that
# blocks EnterPlanMode if no brainstorm sentinel has been recorded for this
# session (i.e., /dso:brainstorm has not been run for the current epic).
#
# Tests verify block/allow behavior of the brainstorm enforcement gate.

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
# Ensure no leftover sentinel from prior runs
rm -f "$ARTIFACTS_DIR/brainstorm-sentinel"

INPUT_NO_SENTINEL="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"test-session-no-sentinel-$$\"}"
EXIT_CODE=$(run_hook_fn "$INPUT_NO_SENTINEL")
assert_eq "test_brainstorm_gate_sentinel_absent_blocks" "2" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_sentinel_present_allows
# Sentinel file exists → hook must return exit 0 (allow)
# (session-scoping comes from get_artifacts_dir() which is unique per repo;
# session ID is not part of the sentinel filename)
# ---------------------------------------------------------------------------
mkdir -p "$ARTIFACTS_DIR"
echo "completed" > "$ARTIFACTS_DIR/brainstorm-sentinel"

INPUT_WITH_SENTINEL="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"test-session-with-sentinel-$$\"}"
EXIT_CODE=$(run_hook_fn "$INPUT_WITH_SENTINEL")
assert_eq "test_brainstorm_gate_sentinel_present_allows" "0" "$EXIT_CODE"

# Cleanup
rm -f "$ARTIFACTS_DIR/brainstorm-sentinel"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_config_disabled_allows
# Config brainstorm.enforce_entry_gate=false → hook returns exit 0 even without sentinel
# ---------------------------------------------------------------------------
TMP_CONFIG_DIR=$(mktemp -d)
TMP_CONFIG_FILE="$TMP_CONFIG_DIR/dso-config.conf"
cat > "$TMP_CONFIG_FILE" <<'CONF'
brainstorm.enforce_entry_gate=false
CONF

rm -f "$ARTIFACTS_DIR/brainstorm-sentinel"

INPUT_GATE_DISABLED="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"test-session-gate-disabled-$$\"}"
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
INPUT_OTHER="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"session_id\":\"test-session-passthrough-$$\"}"
EXIT_CODE=$(run_hook_fn "$INPUT_OTHER")
assert_eq "test_brainstorm_gate_non_enterplanmode_passthrough" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_dispatcher_blocks_without_sentinel (functional dispatcher test)
# Pipe EnterPlanMode JSON to pre-enterplanmode.sh dispatcher → must block (exit 2)
# ---------------------------------------------------------------------------
rm -f "$ARTIFACTS_DIR/brainstorm-sentinel"

INPUT_DISP_BLOCK="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"test-session-dispatcher-block-$$\"}"
EXIT_CODE=$(run_dispatcher "$INPUT_DISP_BLOCK")
assert_eq "test_brainstorm_gate_dispatcher_blocks_without_sentinel" "2" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_dispatcher_allows_with_sentinel (functional dispatcher test)
# Pipe EnterPlanMode JSON to pre-enterplanmode.sh dispatcher with sentinel present → allow (exit 0)
# ---------------------------------------------------------------------------
mkdir -p "$ARTIFACTS_DIR"
echo "completed" > "$ARTIFACTS_DIR/brainstorm-sentinel"

INPUT_DISP_ALLOW="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"test-session-dispatcher-allow-$$\"}"
EXIT_CODE=$(run_dispatcher "$INPUT_DISP_ALLOW")
assert_eq "test_brainstorm_gate_dispatcher_allows_with_sentinel" "0" "$EXIT_CODE"

# Cleanup
rm -f "$ARTIFACTS_DIR/brainstorm-sentinel"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_allowlisted_skill_allows
# When an allowlisted skill context file exists (e.g., fix-bug), hook should
# return exit 0 even without a brainstorm sentinel.
# (This test is RED: hook has no allowlist check yet — will exit 2, not 0)
# ---------------------------------------------------------------------------
mkdir -p "$ARTIFACTS_DIR"
rm -f "$ARTIFACTS_DIR/brainstorm-sentinel"
echo "fix-bug" > "$ARTIFACTS_DIR/active-skill-context"

INPUT_ALLOWLISTED="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"test-session-allowlist-$$\"}"
EXIT_CODE=$(run_hook_fn "$INPUT_ALLOWLISTED")
assert_eq "test_brainstorm_gate_allowlisted_skill_allows" "0" "$EXIT_CODE"

# Cleanup
rm -f "$ARTIFACTS_DIR/active-skill-context"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_unknown_skill_blocks
# When active-skill-context contains an unknown/non-allowlisted skill name,
# hook should still return exit 2 (block) without a brainstorm sentinel.
# (This test is RED: hook has no allowlist check yet — currently exits 2,
# which happens to match, but once allowlist is added the non-allowlisted
# path must still block. Kept as a regression guard.)
# Actually this test asserts current-and-future behavior: unknown skill → block (exit 2)
# ---------------------------------------------------------------------------
mkdir -p "$ARTIFACTS_DIR"
rm -f "$ARTIFACTS_DIR/brainstorm-sentinel"
echo "unknown-skill" > "$ARTIFACTS_DIR/active-skill-context"

INPUT_UNKNOWN="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"test-session-unknown-skill-$$\"}"
EXIT_CODE=$(run_hook_fn "$INPUT_UNKNOWN")
assert_eq "test_brainstorm_gate_unknown_skill_blocks" "2" "$EXIT_CODE"

# Cleanup
rm -f "$ARTIFACTS_DIR/active-skill-context"

# ---------------------------------------------------------------------------
# test_brainstorm_gate_no_skill_context_blocks
# No active-skill-context file and no brainstorm sentinel → hook must block (exit 2).
# Verifies baseline blocking behavior still holds after allowlist feature is added.
# ---------------------------------------------------------------------------
rm -f "$ARTIFACTS_DIR/brainstorm-sentinel"
rm -f "$ARTIFACTS_DIR/active-skill-context"

INPUT_NO_CONTEXT="{\"tool_name\":\"EnterPlanMode\",\"tool_input\":{},\"session_id\":\"test-session-no-context-$$\"}"
EXIT_CODE=$(run_hook_fn "$INPUT_NO_CONTEXT")
assert_eq "test_brainstorm_gate_no_skill_context_blocks" "2" "$EXIT_CODE"

print_summary
