#!/usr/bin/env bash
# tests/scripts/test-plugin-scripts.sh
# Verify the 8 portable scripts were copied to scripts/.
#
# Usage: bash tests/scripts/test-plugin-scripts.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
PLUGIN_SCRIPTS_DIR="$PLUGIN_ROOT/scripts"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-plugin-scripts.sh ==="

# The 8 scripts that must be copied into the plugin
PLUGIN_SCRIPTS=(
    validate.sh
    ci-status.sh
    analyze-tool-use.py
    classify-task.py
    classify-task.sh
    orphaned-tasks.sh
    toggle-tool-logging.sh
    log-dispatch.sh
)

# Bash scripts that must be executable (Python scripts are invoked via python3)
BASH_SCRIPTS=(
    validate.sh
    ci-status.sh
    classify-task.sh
    orphaned-tasks.sh
    toggle-tool-logging.sh
    log-dispatch.sh
)

# ── test_plugin_scripts_exist ─────────────────────────────────────────────────
for script in "${PLUGIN_SCRIPTS[@]}"; do
    target="$PLUGIN_SCRIPTS_DIR/$script"
    if [ -f "$target" ]; then
        actual="exists"
    else
        actual="missing"
    fi
    assert_eq "test_plugin_scripts_exist: $script" "exists" "$actual"
done

# ── test_plugin_scripts_executable ───────────────────────────────────────────
for script in "${BASH_SCRIPTS[@]}"; do
    target="$PLUGIN_SCRIPTS_DIR/$script"
    if [ -x "$target" ]; then
        actual="executable"
    else
        actual="not_executable"
    fi
    assert_eq "test_plugin_scripts_executable: $script" "executable" "$actual"
done

# ── test_plugin_scripts_no_hardcoded_paths ────────────────────────────────────
for script in "${PLUGIN_SCRIPTS[@]}"; do
    target="$PLUGIN_SCRIPTS_DIR/$script"
    if [ ! -f "$target" ]; then
        continue
    fi
    if grep -qE '/Users/joeoakhart|/home/' "$target" 2>/dev/null; then
        actual="has_hardcoded_paths"
    else
        actual="clean"
    fi
    assert_eq "test_plugin_scripts_no_hardcoded_paths: $script" "clean" "$actual"
done

# ── test_plugin_scripts_no_syntax_errors ─────────────────────────────────────
for script in "${BASH_SCRIPTS[@]}"; do
    target="$PLUGIN_SCRIPTS_DIR/$script"
    if [ ! -f "$target" ]; then
        continue
    fi
    if bash -n "$target" 2>/dev/null; then
        actual="valid"
    else
        actual="syntax_error"
    fi
    assert_eq "test_plugin_scripts_no_syntax_errors: $script" "valid" "$actual"
done

print_summary
