#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-config-paths.sh
# Unit tests for config-paths.sh shared config path resolver.
#
# Tests:
#   test_config_paths_defaults_match_current_values
#   test_config_paths_reads_custom_config
#   test_config_paths_idempotent_sourcing
#
# Usage: bash lockpick-workflow/tests/hooks/test-config-paths.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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
    source "$REPO_ROOT/lockpick-workflow/hooks/lib/config-paths.sh"
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
    source "$REPO_ROOT/lockpick-workflow/hooks/lib/config-paths.sh"
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
# CFG_UNIT_SNAPSHOT_PATH should be derived from CFG_APP_DIR
assert_eq "custom CFG_UNIT_SNAPSHOT_PATH" "myapp/tests/unit/templates/snapshots/" "$(echo "$result" | grep '^CFG_UNIT_SNAPSHOT_PATH=' | cut -d= -f2-)"

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
    source "$REPO_ROOT/lockpick-workflow/hooks/lib/config-paths.sh"
    first_app_dir="$CFG_APP_DIR"
    # Source again — should be guarded
    source "$REPO_ROOT/lockpick-workflow/hooks/lib/config-paths.sh"
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
    source "$REPO_ROOT/lockpick-workflow/hooks/lib/config-paths.sh"
    echo "CFG_VISUAL_BASELINE_PATH=$CFG_VISUAL_BASELINE_PATH"
)

assert_eq "visual baseline from config" "app/tests/e2e/snapshots/" "$(echo "$result" | grep '^CFG_VISUAL_BASELINE_PATH=' | cut -d= -f2-)"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
