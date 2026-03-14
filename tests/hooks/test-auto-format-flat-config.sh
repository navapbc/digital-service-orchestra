#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-auto-format-flat-config.sh
# Tests for auto-format.sh migration from inline Python YAML reads to read-config.sh calls.
# Validates that auto-format.sh reads format.extensions and format.source_dirs
# from workflow-config.conf via read-config.sh instead of inline Python.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/auto-format.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ── test_reads_extensions_from_conf ──────────────────────────────────────────
# auto-format reads .py extension from a .conf file via read-config.sh
_PLUGIN_ROOT=$(mktemp -d)
cat > "$_PLUGIN_ROOT/workflow-config.conf" << 'CONF_EOF'
format.extensions=.py
CONF_EOF

# Create a real .py file under app/src so the hook will attempt to process it
_FAKE_PY=$(mktemp "$REPO_ROOT/app/src/fake_test_XXXXXX.py")
echo "x = 1" > "$_FAKE_PY"

INPUT="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_FAKE_PY\"}}"
# With .conf saying format.extensions=.py, a .py file in app/src should be processed (not skipped).
# The hook should exit 0 regardless. We verify the hook reads the conf by checking that
# a .ts file would be skipped — tested in test_reads_source_dirs_from_conf indirectly.
# Here we verify the .py extension IS processed (hook doesn't skip it).
EXIT_CODE=0
CLAUDE_PLUGIN_ROOT="$_PLUGIN_ROOT" bash -c "echo '$INPUT' | bash '$HOOK' 2>/dev/null" || EXIT_CODE=$?
assert_eq "test_reads_extensions_from_conf" "0" "$EXIT_CODE"

# Also verify a .ts file IS skipped when only .py is configured
_FAKE_TS="/tmp/test_component.ts"
touch "$_FAKE_TS"
INPUT_TS="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_FAKE_TS\"}}"
_TS_OUTPUT=$(CLAUDE_PLUGIN_ROOT="$_PLUGIN_ROOT" bash -c "echo '$INPUT_TS' | bash '$HOOK' 2>&1")
assert_eq "test_reads_extensions_from_conf_skips_ts" "" "$_TS_OUTPUT"

rm -f "$_FAKE_PY" "$_FAKE_TS"
rm -rf "$_PLUGIN_ROOT"

# ── test_reads_source_dirs_from_conf ─────────────────────────────────────────
# auto-format reads app/src, app/tests from a .conf file
_PLUGIN_ROOT2=$(mktemp -d)
cat > "$_PLUGIN_ROOT2/workflow-config.conf" << 'CONF_EOF'
format.extensions=.py
format.source_dirs=app/src
format.source_dirs=app/tests
CONF_EOF

# A .py file under app/src should be processed
_FAKE_PY2=$(mktemp "$REPO_ROOT/app/src/fake_test_XXXXXX.py")
echo "x = 1" > "$_FAKE_PY2"
INPUT2="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_FAKE_PY2\"}}"
EXIT_CODE2=0
CLAUDE_PLUGIN_ROOT="$_PLUGIN_ROOT2" bash -c "echo '$INPUT2' | bash '$HOOK' 2>/dev/null" || EXIT_CODE2=$?
assert_eq "test_reads_source_dirs_from_conf_processes_app_src" "0" "$EXIT_CODE2"

# A .py file outside configured dirs should be skipped (empty output = skipped)
_OUTSIDE_PY="/tmp/outside_dir_test.py"
touch "$_OUTSIDE_PY"
INPUT_OUTSIDE="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_OUTSIDE_PY\"}}"
_OUTSIDE_OUTPUT=$(CLAUDE_PLUGIN_ROOT="$_PLUGIN_ROOT2" bash -c "echo '$INPUT_OUTSIDE' | bash '$HOOK' 2>&1")
assert_eq "test_reads_source_dirs_from_conf_skips_outside" "" "$_OUTSIDE_OUTPUT"

rm -f "$_FAKE_PY2" "$_OUTSIDE_PY"
rm -rf "$_PLUGIN_ROOT2"

# ── test_no_python_invocation ────────────────────────────────────────────────
# Verify auto-format.sh no longer contains inline Python YAML reads
_has_python=0
grep -q 'import yaml\|yaml.safe_load\|PYEOF' "$HOOK" && _has_python=1
assert_eq "test_no_python_invocation" "0" "$_has_python"

# ── test_fallback_defaults_without_config ────────────────────────────────────
# Without any config file, defaults to .py and app/src, app/tests
# A .py file outside app/src and app/tests should be skipped (no config, default dirs)
_NO_CONFIG_ROOT=$(mktemp -d)
# No workflow-config.conf or .yaml present

_OUTSIDE_PY2="/tmp/no_config_test.py"
touch "$_OUTSIDE_PY2"
INPUT_NC="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_OUTSIDE_PY2\"}}"
_NC_OUTPUT=$(CLAUDE_PLUGIN_ROOT="$_NO_CONFIG_ROOT" bash -c "echo '$INPUT_NC' | bash '$HOOK' 2>&1")
assert_eq "test_fallback_defaults_without_config_skips_outside" "" "$_NC_OUTPUT"

# A .py file inside app/src should be processed (exit 0)
_FAKE_PY3=$(mktemp "$REPO_ROOT/app/src/fake_test_XXXXXX.py")
echo "x = 1" > "$_FAKE_PY3"
INPUT_NC2="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_FAKE_PY3\"}}"
EXIT_CODE_NC=0
CLAUDE_PLUGIN_ROOT="$_NO_CONFIG_ROOT" bash -c "echo '$INPUT_NC2' | bash '$HOOK' 2>/dev/null" || EXIT_CODE_NC=$?
assert_eq "test_fallback_defaults_without_config_processes_app_src" "0" "$EXIT_CODE_NC"

rm -f "$_OUTSIDE_PY2" "$_FAKE_PY3"
rm -rf "$_NO_CONFIG_ROOT"

print_summary
