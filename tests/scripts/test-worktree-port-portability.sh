#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-worktree-port-portability.sh
# Portability smoke test: worktree-port.sh with no config file (default base
# ports), with custom config (custom base ports), and standalone script checks.
#
# Validates:
#   - No config file present → uses default base ports (5432 + offset, 3000 + offset), exits 0
#   - Custom config (database.base_port: 3306) → uses custom DB base port
#   - Custom config (infrastructure.app_base_port: 8000) → uses custom app base port
#   - Standalone scripts/worktree-port.sh exists, is executable, and produces correct output
#   - Plugin copy (lockpick-workflow/scripts/worktree-port.sh) no longer exists (migrated to standalone)
#
# Usage: bash lockpick-workflow/tests/scripts/test-worktree-port-portability.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STANDALONE_SCRIPT="$REPO_ROOT/scripts/worktree-port.sh"
OLD_PLUGIN_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/worktree-port.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-worktree-port-portability.sh ==="

# ── Resolve python3 with pyyaml for read-config.sh ─────────────────────────
if [[ -z "${CLAUDE_PLUGIN_PYTHON:-}" ]]; then
    for _py_candidate in \
            "$REPO_ROOT/app/.venv/bin/python3" \
            "$REPO_ROOT/.venv/bin/python3" \
            "python3"; do
        [[ -z "$_py_candidate" ]] && continue
        [[ "$_py_candidate" != "python3" ]] && [[ ! -f "$_py_candidate" ]] && continue
        if "$_py_candidate" -c "import yaml" 2>/dev/null; then
            export CLAUDE_PLUGIN_PYTHON="$_py_candidate"
            break
        fi
    done
fi

# ── Compute expected offset for a known worktree name ──────────────────────
# We use a fixed name so tests are deterministic.
TEST_WORKTREE_NAME="test-portability-worktree"
HASH_NUM=$(printf '%s' "$TEST_WORKTREE_NAME" | cksum | cut -d' ' -f1)
PORT_OFFSET=$(( HASH_NUM % 100 + 1 ))

# ── Setup: isolated temp directory ─────────────────────────────────────────
TMPDIR_PORT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PORT"' EXIT

# ==========================================================================
# Test 1: No config file present → default base ports (5432, 3000)
# ==========================================================================
_snapshot_fail

NO_CONFIG_DIR="$TMPDIR_PORT/no-config"
mkdir -p "$NO_CONFIG_DIR"

# Run from a directory with no workflow-config.yaml and no CLAUDE_PLUGIN_ROOT
no_config_exit=0
no_config_output=""
no_config_output=$(
    cd "$NO_CONFIG_DIR"
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$STANDALONE_SCRIPT" "$TEST_WORKTREE_NAME" 2>&1
) || no_config_exit=$?

EXPECTED_DB_PORT_DEFAULT=$(( 5432 + PORT_OFFSET ))
EXPECTED_APP_PORT_DEFAULT=$(( 3000 + PORT_OFFSET ))

assert_eq "test_no_config_exit_0: exit code" "0" "$no_config_exit"
assert_contains "test_no_config_default_db_port: DB_PORT=$EXPECTED_DB_PORT_DEFAULT" \
    "DB_PORT=$EXPECTED_DB_PORT_DEFAULT" "$no_config_output"
assert_contains "test_no_config_default_app_port: APP_PORT=$EXPECTED_APP_PORT_DEFAULT" \
    "APP_PORT=$EXPECTED_APP_PORT_DEFAULT" "$no_config_output"
assert_pass_if_clean "test_no_config_defaults"

# ==========================================================================
# Test 2: No config file, db mode → just the DB port number
# ==========================================================================
_snapshot_fail

no_config_db_exit=0
no_config_db_output=""
no_config_db_output=$(
    cd "$NO_CONFIG_DIR"
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$STANDALONE_SCRIPT" "$TEST_WORKTREE_NAME" db 2>&1
) || no_config_db_exit=$?

assert_eq "test_no_config_db_mode_exit_0: exit code" "0" "$no_config_db_exit"
assert_eq "test_no_config_db_mode_value: port value" "$EXPECTED_DB_PORT_DEFAULT" "$no_config_db_output"
assert_pass_if_clean "test_no_config_db_mode"

# ==========================================================================
# Test 3: No config file, app mode → just the APP port number
# ==========================================================================
_snapshot_fail

no_config_app_exit=0
no_config_app_output=""
no_config_app_output=$(
    cd "$NO_CONFIG_DIR"
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$STANDALONE_SCRIPT" "$TEST_WORKTREE_NAME" app 2>&1
) || no_config_app_exit=$?

assert_eq "test_no_config_app_mode_exit_0: exit code" "0" "$no_config_app_exit"
assert_eq "test_no_config_app_mode_value: port value" "$EXPECTED_APP_PORT_DEFAULT" "$no_config_app_output"
assert_pass_if_clean "test_no_config_app_mode"

# ==========================================================================
# Test 4: Custom config — database.base_port: 3306
# ==========================================================================
_snapshot_fail

CUSTOM_DB_DIR="$TMPDIR_PORT/custom-db"
mkdir -p "$CUSTOM_DB_DIR"
cat > "$CUSTOM_DB_DIR/workflow-config.yaml" <<'YAML'
version: "1.0.0"
database:
  base_port: 3306
YAML

custom_db_exit=0
custom_db_output=""
custom_db_output=$(
    cd "$CUSTOM_DB_DIR"
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$STANDALONE_SCRIPT" "$TEST_WORKTREE_NAME" db 2>&1
) || custom_db_exit=$?

EXPECTED_DB_PORT_CUSTOM=$(( 3306 + PORT_OFFSET ))

assert_eq "test_custom_db_base_port_exit_0: exit code" "0" "$custom_db_exit"
assert_eq "test_custom_db_base_port_value: port value" "$EXPECTED_DB_PORT_CUSTOM" "$custom_db_output"
assert_pass_if_clean "test_custom_db_base_port"

# ==========================================================================
# Test 5: Custom config — infrastructure.app_base_port: 8000
# ==========================================================================
_snapshot_fail

CUSTOM_APP_DIR="$TMPDIR_PORT/custom-app"
mkdir -p "$CUSTOM_APP_DIR"
cat > "$CUSTOM_APP_DIR/workflow-config.yaml" <<'YAML'
version: "1.0.0"
infrastructure:
  app_base_port: 8000
YAML

custom_app_exit=0
custom_app_output=""
custom_app_output=$(
    cd "$CUSTOM_APP_DIR"
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$STANDALONE_SCRIPT" "$TEST_WORKTREE_NAME" app 2>&1
) || custom_app_exit=$?

EXPECTED_APP_PORT_CUSTOM=$(( 8000 + PORT_OFFSET ))

assert_eq "test_custom_app_base_port_exit_0: exit code" "0" "$custom_app_exit"
assert_eq "test_custom_app_base_port_value: port value" "$EXPECTED_APP_PORT_CUSTOM" "$custom_app_output"
assert_pass_if_clean "test_custom_app_base_port"

# ==========================================================================
# Test 6: Custom config — both base ports set
# ==========================================================================
_snapshot_fail

CUSTOM_BOTH_DIR="$TMPDIR_PORT/custom-both"
mkdir -p "$CUSTOM_BOTH_DIR"
cat > "$CUSTOM_BOTH_DIR/workflow-config.yaml" <<'YAML'
version: "1.0.0"
database:
  base_port: 3306
infrastructure:
  app_base_port: 8000
YAML

custom_both_exit=0
custom_both_output=""
custom_both_output=$(
    cd "$CUSTOM_BOTH_DIR"
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$STANDALONE_SCRIPT" "$TEST_WORKTREE_NAME" 2>&1
) || custom_both_exit=$?

EXPECTED_DB_BOTH=$(( 3306 + PORT_OFFSET ))
EXPECTED_APP_BOTH=$(( 8000 + PORT_OFFSET ))

assert_eq "test_custom_both_exit_0: exit code" "0" "$custom_both_exit"
assert_contains "test_custom_both_db_port: DB_PORT=$EXPECTED_DB_BOTH" \
    "DB_PORT=$EXPECTED_DB_BOTH" "$custom_both_output"
assert_contains "test_custom_both_app_port: APP_PORT=$EXPECTED_APP_BOTH" \
    "APP_PORT=$EXPECTED_APP_BOTH" "$custom_both_output"
assert_pass_if_clean "test_custom_both_ports"

# ==========================================================================
# Test 7: Standalone script — scripts/worktree-port.sh exists and works
# ==========================================================================
_snapshot_fail

# 7a. Standalone script must exist
if [[ -f "$STANDALONE_SCRIPT" ]]; then
    assert_eq "test_standalone_exists: file exists" "yes" "yes"
else
    assert_eq "test_standalone_exists: file exists" "yes" "no"
fi

# 7b. Standalone script must be executable
if [[ -x "$STANDALONE_SCRIPT" ]]; then
    assert_eq "test_standalone_executable: executable" "yes" "yes"
else
    assert_eq "test_standalone_executable: executable" "yes" "no"
fi

# 7c. Standalone script must be self-contained (not a thin wrapper)
standalone_lines=$(wc -l < "$STANDALONE_SCRIPT" | tr -d ' ')
if [[ "$standalone_lines" -gt 10 ]]; then
    assert_eq "test_standalone_not_wrapper: > 10 lines (standalone)" "yes" "yes"
else
    assert_eq "test_standalone_not_wrapper: > 10 lines (got $standalone_lines)" "yes" "no"
fi

# 7d. Standalone script produces correct output
standalone_output=$(
    cd "$NO_CONFIG_DIR"
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$STANDALONE_SCRIPT" "$TEST_WORKTREE_NAME" 2>&1
) || true

assert_eq "test_standalone_output: matches expected" "$no_config_output" "$standalone_output"

assert_pass_if_clean "test_standalone_script"

# ==========================================================================
# Test 8: Plugin copy removed — lockpick-workflow/scripts/worktree-port.sh must NOT exist
# ==========================================================================
_snapshot_fail

if [[ ! -f "$OLD_PLUGIN_SCRIPT" ]]; then
    assert_eq "test_plugin_script_removed: file absent" "yes" "yes"
else
    assert_eq "test_plugin_script_removed: file absent (still exists)" "yes" "no"
fi

assert_pass_if_clean "test_plugin_script_removed"

# ==========================================================================
print_summary
