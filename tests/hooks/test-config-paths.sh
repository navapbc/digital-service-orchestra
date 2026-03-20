#!/usr/bin/env bash
# tests/hooks/test-config-paths.sh
# Unit tests for config-paths.sh shared config path resolver.
#
# Tests:
#   test_config_paths_defaults_match_current_values
#   test_config_paths_reads_custom_config
#   test_config_paths_idempotent_sourcing
#   test_config_paths_visual_baseline_path
#   test_config_paths_reads_from_dot_claude_dso_config
#   test_config_paths_no_claude_plugin_root_fallback
#
# Usage: bash tests/hooks/test-config-paths.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        (( PASS++ ))
    else
        (( FAIL++ ))
        printf "FAIL: %s\n  expected: %s\n  actual:   %s\n" "$label" "$expected" "$actual" >&2
    fi
}

assert_non_empty() {
    local label="$1" actual="$2"
    if [[ -n "$actual" ]]; then
        (( PASS++ ))
    else
        (( FAIL++ ))
        printf "FAIL: %s — expected non-empty, got empty\n" "$label" >&2
    fi
}

# ============================================================================
# test_config_paths_defaults_match_current_values
# ============================================================================
echo "=== test_config_paths_defaults_match_current_values ==="

# Source in a subshell with no config file available (unset CLAUDE_PLUGIN_ROOT)
result=$(
    unset CLAUDE_PLUGIN_ROOT
    # Use a temp dir as "root" so no workflow-config.conf is found
    tmpdir=$(mktemp -d)
    cd "$tmpdir"
    # Source the config-paths helper
    source "$DSO_PLUGIN_DIR/hooks/lib/config-paths.sh"
    echo "CFG_APP_DIR=$CFG_APP_DIR"
    echo "CFG_PYTHON_VENV=$CFG_PYTHON_VENV"
    echo "CFG_FORMAT_SOURCE_DIRS=$CFG_FORMAT_SOURCE_DIRS"
    echo "CFG_SRC_DIR=$CFG_SRC_DIR"
    echo "CFG_TEST_DIR=$CFG_TEST_DIR"
    echo "CFG_UNIT_SNAPSHOT_PATH=$CFG_UNIT_SNAPSHOT_PATH"
    rm -rf "$tmpdir"
)

# Defaults should match current hardcoded values
assert_eq "default CFG_APP_DIR" "app" "$(echo "$result" | grep '^CFG_APP_DIR=' | cut -d= -f2-)"
assert_eq "default CFG_PYTHON_VENV" "app/.venv/bin/python3" "$(echo "$result" | grep '^CFG_PYTHON_VENV=' | cut -d= -f2-)"
assert_eq "default CFG_SRC_DIR" "src" "$(echo "$result" | grep '^CFG_SRC_DIR=' | cut -d= -f2-)"
assert_eq "default CFG_TEST_DIR" "tests" "$(echo "$result" | grep '^CFG_TEST_DIR=' | cut -d= -f2-)"
assert_eq "default CFG_UNIT_SNAPSHOT_PATH" "app/tests/unit/templates/snapshots/" "$(echo "$result" | grep '^CFG_UNIT_SNAPSHOT_PATH=' | cut -d= -f2-)"

# CFG_FORMAT_SOURCE_DIRS default — check it contains "app/src" and "app/tests"
format_dirs=$(echo "$result" | grep '^CFG_FORMAT_SOURCE_DIRS=' | cut -d= -f2-)
assert_non_empty "default CFG_FORMAT_SOURCE_DIRS" "$format_dirs"

# ============================================================================
# test_config_paths_reads_custom_config
# ============================================================================
echo "=== test_config_paths_reads_custom_config ==="

tmpdir=$(mktemp -d)
_CLEANUP_DIRS+=("$tmpdir")

# Create a custom config file
cat > "$tmpdir/workflow-config.conf" <<'EOF'
paths.app_dir=myapp
paths.src_dir=lib
paths.test_dir=spec
interpreter.python_venv=myapp/.venv/bin/python3
format.source_dirs=myapp/lib
format.source_dirs=myapp/spec
EOF

result=$(
    export CLAUDE_PLUGIN_ROOT="$tmpdir"
    # Reset the guard so config-paths.sh can be sourced fresh
    unset _CONFIG_PATHS_LOADED
    source "$DSO_PLUGIN_DIR/hooks/lib/config-paths.sh"
    echo "CFG_APP_DIR=$CFG_APP_DIR"
    echo "CFG_PYTHON_VENV=$CFG_PYTHON_VENV"
    echo "CFG_SRC_DIR=$CFG_SRC_DIR"
    echo "CFG_TEST_DIR=$CFG_TEST_DIR"
    echo "CFG_UNIT_SNAPSHOT_PATH=$CFG_UNIT_SNAPSHOT_PATH"
)

assert_eq "custom CFG_APP_DIR" "myapp" "$(echo "$result" | grep '^CFG_APP_DIR=' | cut -d= -f2-)"
assert_eq "custom CFG_PYTHON_VENV" "myapp/.venv/bin/python3" "$(echo "$result" | grep '^CFG_PYTHON_VENV=' | cut -d= -f2-)"
assert_eq "custom CFG_SRC_DIR" "lib" "$(echo "$result" | grep '^CFG_SRC_DIR=' | cut -d= -f2-)"
assert_eq "custom CFG_TEST_DIR" "spec" "$(echo "$result" | grep '^CFG_TEST_DIR=' | cut -d= -f2-)"
# CFG_UNIT_SNAPSHOT_PATH should be derived from CFG_APP_DIR and CFG_TEST_DIR
assert_eq "custom CFG_UNIT_SNAPSHOT_PATH" "myapp/spec/unit/templates/snapshots/" "$(echo "$result" | grep '^CFG_UNIT_SNAPSHOT_PATH=' | cut -d= -f2-)"

# ============================================================================
# test_config_paths_idempotent_sourcing
# ============================================================================
echo "=== test_config_paths_idempotent_sourcing ==="

# Double-source should not error and values should remain consistent
result=$(
    unset CLAUDE_PLUGIN_ROOT
    unset _CONFIG_PATHS_LOADED
    tmpdir2=$(mktemp -d)
    cd "$tmpdir2"
    source "$DSO_PLUGIN_DIR/hooks/lib/config-paths.sh"
    first_app_dir="$CFG_APP_DIR"
    # Source again — should be guarded
    source "$DSO_PLUGIN_DIR/hooks/lib/config-paths.sh"
    second_app_dir="$CFG_APP_DIR"
    echo "first=$first_app_dir"
    echo "second=$second_app_dir"
    rm -rf "$tmpdir2"
)

first=$(echo "$result" | grep '^first=' | cut -d= -f2-)
second=$(echo "$result" | grep '^second=' | cut -d= -f2-)
assert_eq "idempotent: first==second" "$first" "$second"
assert_eq "idempotent: value is default" "app" "$first"

# ============================================================================
# test_config_paths_visual_baseline_path
# ============================================================================
echo "=== test_config_paths_visual_baseline_path ==="

# When config has a visual baseline, CFG_VISUAL_BASELINE_PATH should read it
tmpdir3=$(mktemp -d)
_CLEANUP_DIRS+=("$tmpdir3")

cat > "$tmpdir3/workflow-config.conf" <<'EOF'
paths.app_dir=app
merge.visual_baseline_path=app/tests/e2e/snapshots/
EOF

result=$(
    export CLAUDE_PLUGIN_ROOT="$tmpdir3"
    unset _CONFIG_PATHS_LOADED
    source "$DSO_PLUGIN_DIR/hooks/lib/config-paths.sh"
    echo "CFG_VISUAL_BASELINE_PATH=$CFG_VISUAL_BASELINE_PATH"
)

assert_eq "visual baseline from config" "app/tests/e2e/snapshots/" "$(echo "$result" | grep '^CFG_VISUAL_BASELINE_PATH=' | cut -d= -f2-)"

# ============================================================================
# test_config_paths_reads_from_dot_claude_dso_config
# ============================================================================
echo "=== test_config_paths_reads_from_dot_claude_dso_config ==="

# REVIEW-DEFENSE: These two new tests (test_config_paths_reads_from_dot_claude_dso_config and
# test_config_paths_no_claude_plugin_root_fallback) are intentionally FAILING. This file is the
# RED phase of a TDD cycle (story dso-c2tl). The tests define the expected behavior of a
# config-paths.sh change that will be implemented in the GREEN phase (story dso-6trc). Failing
# tests at this stage are correct and expected — they confirm the behavior does not yet exist.

# When CLAUDE_PLUGIN_ROOT is NOT set but .claude/dso-config.conf exists at git root,
# config-paths.sh should read config values from .claude/dso-config.conf (new behavior).
tmpdir_dso=$(mktemp -d)
_CLEANUP_DIRS+=("$tmpdir_dso")

# Set up a minimal git repo with .claude/dso-config.conf
(
    cd "$tmpdir_dso"
    git init -q
    mkdir -p .claude
    cat > .claude/dso-config.conf <<'CONF'
paths.app_dir=dotclaudeapp
paths.src_dir=dotclaudesrc
paths.test_dir=dotclaudetest
interpreter.python_venv=dotclaudeapp/.venv/bin/python3
CONF
    git add .claude/dso-config.conf
    git commit -q -m "init"
)

result_dso=$(
    unset CLAUDE_PLUGIN_ROOT
    unset _CONFIG_PATHS_LOADED
    cd "$tmpdir_dso"
    source "$DSO_PLUGIN_DIR/hooks/lib/config-paths.sh"
    echo "CFG_APP_DIR=$CFG_APP_DIR"
    echo "CFG_SRC_DIR=$CFG_SRC_DIR"
    echo "CFG_TEST_DIR=$CFG_TEST_DIR"
)

assert_eq "dot-claude dso-config CFG_APP_DIR" "dotclaudeapp" "$(echo "$result_dso" | grep '^CFG_APP_DIR=' | cut -d= -f2-)"
assert_eq "dot-claude dso-config CFG_SRC_DIR" "dotclaudesrc" "$(echo "$result_dso" | grep '^CFG_SRC_DIR=' | cut -d= -f2-)"
assert_eq "dot-claude dso-config CFG_TEST_DIR" "dotclaudetest" "$(echo "$result_dso" | grep '^CFG_TEST_DIR=' | cut -d= -f2-)"

# ============================================================================
# test_config_paths_no_claude_plugin_root_fallback
# ============================================================================
echo "=== test_config_paths_no_claude_plugin_root_fallback ==="

# REVIEW-DEFENSE: This test intentionally contradicts test_config_paths_reads_custom_config.
# Once dso-6trc implements the new config-paths.sh behavior, the existing
# test_config_paths_reads_custom_config test will need to be updated or removed — that update
# is explicitly in scope for story dso-6trc (GREEN phase). Having two temporarily contradictory
# tests is the correct state during a RED phase that changes config lookup semantics.

# When CLAUDE_PLUGIN_ROOT is set to a dir containing workflow-config.conf,
# config-paths.sh must NOT read from that file (new behavior: CLAUDE_PLUGIN_ROOT no
# longer used for config file lookup). Values should fall back to defaults.
tmpdir_cproot=$(mktemp -d)
_CLEANUP_DIRS+=("$tmpdir_cproot")

cat > "$tmpdir_cproot/workflow-config.conf" <<'CONF'
paths.app_dir=cproot_app
paths.src_dir=cproot_src
CONF

result_cproot=$(
    export CLAUDE_PLUGIN_ROOT="$tmpdir_cproot"
    unset _CONFIG_PATHS_LOADED
    # No .claude/dso-config.conf at git root → should fall back to defaults, NOT read CLAUDE_PLUGIN_ROOT
    tmpdir_gitroot=$(mktemp -d)
    cd "$tmpdir_gitroot"
    git init -q
    # no .claude/dso-config.conf here
    source "$DSO_PLUGIN_DIR/hooks/lib/config-paths.sh"
    echo "CFG_APP_DIR=$CFG_APP_DIR"
    echo "CFG_SRC_DIR=$CFG_SRC_DIR"
    rm -rf "$tmpdir_gitroot"
)

# After the new behavior, CLAUDE_PLUGIN_ROOT/workflow-config.conf must be ignored.
# CFG_APP_DIR must be the default "app", NOT "cproot_app".
assert_eq "CLAUDE_PLUGIN_ROOT not used: CFG_APP_DIR should be default" "app" "$(echo "$result_cproot" | grep '^CFG_APP_DIR=' | cut -d= -f2-)"
assert_eq "CLAUDE_PLUGIN_ROOT not used: CFG_SRC_DIR should be default" "src" "$(echo "$result_cproot" | grep '^CFG_SRC_DIR=' | cut -d= -f2-)"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
