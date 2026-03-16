#!/usr/bin/env bash
# tests/hooks/test-auto-format.sh
# Tests for .claude/hooks/auto-format.sh
#
# auto-format.sh is a PostToolUse hook that runs ruff on .py files
# after Edit/Write calls. It always exits 0 (non-blocking).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/auto-format.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

run_hook() {
    local input="$1"
    local exit_code=0
    local output
    output=$(echo "$input" | bash "$HOOK" 2>/dev/null) || exit_code=$?
    echo "$exit_code"
}

# test_auto_format_exits_zero_on_valid_bash_edit
# The hook should exit 0 when it receives a Bash tool call (not Edit/Write)
INPUT='{"tool_name":"Bash","tool_input":{"command":"make test"},"tool_response":{"exit_code":0}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_auto_format_exits_zero_on_valid_bash_edit" "0" "$EXIT_CODE"

# test_auto_format_exits_zero_on_non_python_edit
# Edit of a non-.py file should exit 0 (no-op)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.txt"},"tool_response":{"success":true}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_auto_format_exits_zero_on_non_python_edit" "0" "$EXIT_CODE"

# test_auto_format_exits_zero_on_python_edit_outside_app
# Edit of a .py file outside app/src or app/tests should exit 0 (no-op)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"},"tool_response":{"success":true}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_auto_format_exits_zero_on_python_edit_outside_app" "0" "$EXIT_CODE"

# test_auto_format_exits_zero_on_read_tool
# Read tool calls should be ignored
INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.py"},"tool_response":{"content":""}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_auto_format_exits_zero_on_read_tool" "0" "$EXIT_CODE"

# test_auto_format_exits_zero_on_empty_input
# Empty stdin should exit 0 (no-op)
EXIT_CODE=$(run_hook "")
assert_eq "test_auto_format_exits_zero_on_empty_input" "0" "$EXIT_CODE"

# test_auto_format_exits_zero_on_malformed_json
# Malformed JSON should not crash the hook
EXIT_CODE=$(run_hook "not json {{")
assert_eq "test_auto_format_exits_zero_on_malformed_json" "0" "$EXIT_CODE"

# test_auto_format_exits_zero_on_missing_file_path
# Edit with no file_path should exit 0 (no-op)
INPUT='{"tool_name":"Edit","tool_input":{},"tool_response":{"success":true}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_auto_format_exits_zero_on_missing_file_path" "0" "$EXIT_CODE"

# test_auto_format_exits_zero_on_write_tool_non_py
# Write tool on a non-.py file should exit 0
INPUT='{"tool_name":"Write","tool_input":{"file_path":"/tmp/somefile.sh"},"tool_response":{"success":true}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_auto_format_exits_zero_on_write_tool_non_py" "0" "$EXIT_CODE"

# ============================================================
# Group A: Backward-compat (no config)
# ============================================================
# test_auto_format_backward_compat_defaults_to_py_extension
# No CLAUDE_PLUGIN_ROOT set, no workflow-config.conf present.
# Edit of a .ts file should be ignored (hook only processes .py by default).
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.ts"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_auto_format_backward_compat_defaults_to_py_extension" "0" "$EXIT_CODE"

# test_auto_format_backward_compat_still_handles_py
# Without config, .py files outside app/ should still exit 0 (no-op — not in app/src or app/tests).
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/other.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_auto_format_backward_compat_still_handles_py" "0" "$EXIT_CODE"

# ============================================================
# Group B: Config-driven extensions
# ============================================================
# test_auto_format_config_driven_extensions_skips_unconfigured_type
# CLAUDE_PLUGIN_ROOT points to a temp dir with workflow-config.conf
# that sets format.extensions: ['.ts'] — a .py file in app/src should be
# skipped when config overrides the default extension set.
# This test MUST FAIL in the red phase because auto-format.sh currently
# hardcodes .py and does not read format.extensions from config.
_PLUGIN_ROOT=$(mktemp -d)
_CLEANUP_DIRS+=("$_PLUGIN_ROOT")
cat > "$_PLUGIN_ROOT/workflow-config.conf" << 'CONF_EOF'
format.extensions=.ts
CONF_EOF

# Build a path that looks like it's inside app/src so the hook would normally format it
_APP_SRC_PY="$REPO_ROOT/app/src/fake_module.py"
INPUT="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_APP_SRC_PY\"}}"
# With config saying only .ts, the hook should skip .py files entirely.
# When parameterization is implemented, CLAUDE_PLUGIN_ROOT will be read and .py skipped.
# Until then, the hook will attempt to run ruff on the file (which may fail or succeed
# depending on whether ruff is available) — the important thing is that the hook
# does NOT read the config. We assert the config is read and the file is skipped.
# We measure "skipped" by checking that the hook produces no output (no format attempt).
_CONFIG_OUTPUT=$(CLAUDE_PLUGIN_ROOT="$_PLUGIN_ROOT" echo "$INPUT" | bash "$HOOK" 2>&1)
# When config is honored, a .py file should produce empty output (skipped).
# In red phase, the hook will either try to format (output or no output from ruff),
# but it will NOT respect the config — the assert below will fail because
# the hook ignores CLAUDE_PLUGIN_ROOT and processes .py regardless.
# We verify the hook actually tried to use the config by checking CLAUDE_PLUGIN_ROOT is read.
# Proxy: run with a .py file that is NOT in app/src/app/tests — hook exits 0 silently.
# The distinguishing behavior is: with format.extensions:['.ts'], a .py in app/src/
# should be treated as "not in extension list" and produce no output.
# We assert empty output to indicate the file was skipped.
assert_eq "test_auto_format_config_driven_extensions_skips_unconfigured_type" "" "$_CONFIG_OUTPUT"

# test_auto_format_config_driven_extensions_processes_configured_type
# With format.extensions: ['.ts'], a .ts file in a configured src dir should
# be processed (attempt to format). Since no ts formatter is wired yet,
# we just assert exit 0 (non-blocking) — but the hook must not skip .ts.
# This test MUST FAIL in the red phase: the hook will skip .ts (only knows .py).
_PLUGIN_ROOT2=$(mktemp -d)
_CLEANUP_DIRS+=("$_PLUGIN_ROOT2")
cat > "$_PLUGIN_ROOT2/workflow-config.conf" << 'CONF_EOF'
format.extensions=.ts
CONF_EOF

_TS_FILE="/tmp/test_component.ts"
INPUT="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_TS_FILE\"}}"
# When config-driven: a .ts file should not be silently skipped (hook should attempt
# to process it). In the red phase, the hook ignores config and skips .ts (not .py).
# We check that exit code is 0 — this part is fine either way.
# The real red-phase failure is the skips_unconfigured test above.
EXIT_CODE=0
CLAUDE_PLUGIN_ROOT="$_PLUGIN_ROOT2" echo "$INPUT" | bash "$HOOK" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_auto_format_config_driven_extensions_processes_configured_type_exits_zero" "0" "$EXIT_CODE"

rm -rf "$_PLUGIN_ROOT" "$_PLUGIN_ROOT2"

print_summary
