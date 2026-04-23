#!/usr/bin/env bash
# tests/hooks/test-auto-format-commands-format.sh
# Tests that auto-format.sh uses commands.format from dso-config.conf for .py files
# instead of hardcoding `poetry run ruff`.
#
# Bug 3d8a-b01b: auto-format.sh hardcodes `poetry run ruff` for .py files
# instead of reading commands.format from config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/auto-format.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Single temp directory for all test artifacts — cleaned up on exit
_TEST_ARTIFACTS=$(mktemp -d "${TMPDIR:-/tmp}/test-auto-format-cmd-XXXXXX")
trap 'rm -rf "$_TEST_ARTIFACTS"' EXIT

# Helper: create a minimal fake git repo with app/src/ structure
_make_fake_repo() {
    local repo_dir="$1"
    mkdir -p "$repo_dir/app/src" "$repo_dir/app/tests"
    git -C "$repo_dir" init -q 2>/dev/null
    git -C "$repo_dir" config user.email "test@test.com" 2>/dev/null
    git -C "$repo_dir" config user.name "Test" 2>/dev/null
}

# Create a shared fake repo for tests that need .py files in app/src/
_FAKE_REPO="$_TEST_ARTIFACTS/fake-repo"
_make_fake_repo "$_FAKE_REPO"
# Resolve to canonical path (macOS /var -> /private/var symlink)
_FAKE_REPO="$(cd "$_FAKE_REPO" && pwd -P)"

# ── test_py_file_uses_commands_format_not_hardcoded_ruff ──────────────────────
# When commands.format is set in dso-config.conf, auto-format.sh should use it
# for .py files instead of hardcoded `poetry run ruff ...`.
# We verify this by setting commands.format to a sentinel command that writes
# a marker file, then checking the marker was written.

_PLUGIN_ROOT="$_TEST_ARTIFACTS/plugin-cmd-format"
mkdir -p "$_PLUGIN_ROOT/.claude"

# Create a sentinel script that proves it was called
_SENTINEL_FILE="$_TEST_ARTIFACTS/format-was-called"
_SENTINEL_CMD="$_TEST_ARTIFACTS/mock-formatter.sh"
cat > "$_SENTINEL_CMD" << EOF
#!/usr/bin/env bash
touch "$_SENTINEL_FILE"
EOF
chmod +x "$_SENTINEL_CMD"

cat > "$_PLUGIN_ROOT/.claude/dso-config.conf" << EOF
format.extensions=.py
commands.format=$_SENTINEL_CMD
EOF

# Create a .py file inside the fake repo's app/src
_FAKE_PY="$_FAKE_REPO/app/src/test_commands_format.py"
echo "x = 1" > "$_FAKE_PY"

INPUT="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_FAKE_PY\"}}"

# Run hook with our plugin root pointing to config with commands.format set
rm -f "$_SENTINEL_FILE"
CLAUDE_PLUGIN_ROOT="$_PLUGIN_ROOT" bash -c "cd '$_FAKE_REPO' && echo '$INPUT' | bash '$HOOK' 2>/dev/null" || true

# The sentinel file proves commands.format was used instead of hardcoded poetry run ruff
_SENTINEL_EXISTS=0
[[ -f "$_SENTINEL_FILE" ]] && _SENTINEL_EXISTS=1

assert_eq "test_py_file_uses_commands_format_when_configured" "1" "$_SENTINEL_EXISTS"

# ── test_py_file_falls_back_when_commands_format_not_set ──────────────────────
# When commands.format is NOT set in dso-config.conf, the hook should still
# exit 0 (non-blocking). This tests backward-compat graceful fallback.

_PLUGIN_ROOT2="$_TEST_ARTIFACTS/plugin-no-cmd-format"
mkdir -p "$_PLUGIN_ROOT2/.claude"
cat > "$_PLUGIN_ROOT2/.claude/dso-config.conf" << 'CONF_EOF'
format.extensions=.py
CONF_EOF

_FAKE_PY2="$_FAKE_REPO/app/src/test_fallback.py"
echo "x = 1" > "$_FAKE_PY2"

INPUT2="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_FAKE_PY2\"}}"
EXIT_CODE2=0
CLAUDE_PLUGIN_ROOT="$_PLUGIN_ROOT2" bash -c "cd '$_FAKE_REPO' && echo '$INPUT2' | bash '$HOOK' 2>/dev/null" || EXIT_CODE2=$?

assert_eq "test_py_file_no_commands_format_exits_zero" "0" "$EXIT_CODE2"

# ── test_py_file_commands_format_takes_precedence_over_ruff ──────────────────
# Source-level check: the hook must check commands.format BEFORE falling back to
# `poetry run ruff`. We verify structural ordering: the commands.format read must
# appear in the source before the poetry run ruff invocation.
#
# The fix preserves a ruff fallback for backward compat, but commands.format must
# be evaluated first. We check the line number ordering in the source.
_HOOK_SOURCE=$(cat "$HOOK")
_FORMAT_CMD_LINE=$(grep -n 'commands\.format' "$HOOK" | head -1 | cut -d: -f1)
_RUFF_LINE=$(grep -n 'poetry run ruff check --select I --fix' "$HOOK" | head -1 | cut -d: -f1)

_ORDERING_CORRECT=0
if [[ -n "$_FORMAT_CMD_LINE" && -n "$_RUFF_LINE" ]] && [[ "$_FORMAT_CMD_LINE" -lt "$_RUFF_LINE" ]]; then
    _ORDERING_CORRECT=1
fi

assert_eq "test_py_file_commands_format_evaluated_before_ruff" "1" "$_ORDERING_CORRECT"

# ── test_non_python_file_without_commands_format_emits_warn ──────────────────
# Behavioral: when commands.format is absent and the file is NOT .py, the hook
# must emit [DSO WARN] to stdout (DD2). We run the hook with a .js file
# configured as a format extension but no commands.format set.

_CONF3="$_TEST_ARTIFACTS/dso-config-warn-test.conf"
cat > "$_CONF3" << 'CONF3'
format.extensions=.js
CONF3

_FAKE_JS="$_FAKE_REPO/app/src/test_warn.js"
echo "const x = 1;" > "$_FAKE_JS"
INPUT3="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_FAKE_JS\"}}"

_HOOK_OUTPUT3=""
_HOOK_OUTPUT3=$(WORKFLOW_CONFIG_FILE="$_CONF3" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash -c "cd '$_FAKE_REPO' && echo '$INPUT3' | bash '$HOOK'" 2>/dev/null || true)

_WARN_IN_OUTPUT3=0
if echo "$_HOOK_OUTPUT3" | grep -q '\[DSO WARN\]'; then
    _WARN_IN_OUTPUT3=1
fi

assert_eq "test_non_python_file_without_commands_format_emits_warn" "1" "$_WARN_IN_OUTPUT3"

print_summary
