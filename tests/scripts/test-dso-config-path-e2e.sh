#!/usr/bin/env bash
# tests/scripts/test-dso-config-path-e2e.sh
# Integration tests: full read-config.sh resolution chain end-to-end.
#
# Exercises the complete resolution chain:
#   read-config.sh → .claude/dso-config.conf
#   config-paths.sh → read-config.sh → .claude/dso-config.conf
#   shim (--lib mode) → .claude/dso-config.conf → DSO_ROOT
#   validate.sh + CONFIG_FILE env → .claude/dso-config.conf
#
# Each scenario uses an isolated temp git repo.
#
# Usage: bash tests/scripts/test-dso-config-path-e2e.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
READ_CONFIG="$DSO_PLUGIN_DIR/scripts/read-config.sh"
CONFIG_PATHS="$DSO_PLUGIN_DIR/hooks/lib/config-paths.sh"
SHIM="$PLUGIN_ROOT/.claude/scripts/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-dso-config-path-e2e.sh ==="

# Cleanup tracker for temp dirs
_e2e_tmpdirs=()
_e2e_cleanup() {
    for d in "${_e2e_tmpdirs[@]+"${_e2e_tmpdirs[@]}"}"; do
        rm -rf "$d"
    done
}
trap '_e2e_cleanup' EXIT

# Helper: create an isolated temp git repo
_make_temp_repo() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _e2e_tmpdirs+=("$tmpdir")
    git -C "$tmpdir" init -q
    echo "$tmpdir"
}

# ── test_e2e_resolution_from_dot_claude_dso_config ───────────────────────────
# Given a minimal temp git repo with .claude/dso-config.conf, calling
# read-config.sh (no explicit config arg) returns correct values.
_snapshot_fail
_repo="$(_make_temp_repo)"
mkdir -p "$_repo/.claude"
cat > "$_repo/.claude/dso-config.conf" <<'CONF'
test_command=make test-e2e
paths.app_dir=myapp
CONF

# Unset isolation env vars so auto-discovery runs
_rdcd_exit=0
_rdcd_output=""
_rdcd_output=$(
    cd "$_repo" &&
    unset WORKFLOW_CONFIG_FILE 2>/dev/null || true
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$READ_CONFIG" "test_command" 2>&1
) || _rdcd_exit=$?

assert_eq "test_e2e_resolution_from_dot_claude_dso_config: exit 0" "0" "$_rdcd_exit"
assert_eq "test_e2e_resolution_from_dot_claude_dso_config: reads test_command" "make test-e2e" "$_rdcd_output"

# Also verify a dot-notation key resolves correctly
_rdcd2_exit=0
_rdcd2_output=""
_rdcd2_output=$(
    cd "$_repo" &&
    unset WORKFLOW_CONFIG_FILE 2>/dev/null || true
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$READ_CONFIG" "paths.app_dir" 2>&1
) || _rdcd2_exit=$?

assert_eq "test_e2e_resolution_from_dot_claude_dso_config: reads paths.app_dir exit 0" "0" "$_rdcd2_exit"
assert_eq "test_e2e_resolution_from_dot_claude_dso_config: reads paths.app_dir value" "myapp" "$_rdcd2_output"

assert_pass_if_clean "test_e2e_resolution_from_dot_claude_dso_config"

# ── test_e2e_graceful_degradation_no_config ───────────────────────────────────
# Given a temp git repo with NO config file at either path, read-config.sh
# returns empty output and exits 0 (graceful degradation).
_snapshot_fail
_repo_empty="$(_make_temp_repo)"

_noconf_exit=0
_noconf_output=""
_noconf_output=$(
    cd "$_repo_empty" &&
    unset WORKFLOW_CONFIG_FILE 2>/dev/null || true
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$READ_CONFIG" "test_command" 2>&1
) || _noconf_exit=$?

assert_eq "test_e2e_graceful_degradation_no_config: exit 0" "0" "$_noconf_exit"
assert_eq "test_e2e_graceful_degradation_no_config: empty output" "" "$_noconf_output"

assert_pass_if_clean "test_e2e_graceful_degradation_no_config"

# ── test_e2e_config_paths_reads_from_dot_claude ──────────────────────────────
# Given a temp git repo with .claude/dso-config.conf containing
# paths.app_dir=myapp, sourcing config-paths.sh produces CFG_APP_DIR=myapp.
_snapshot_fail
_repo_cp="$(_make_temp_repo)"
mkdir -p "$_repo_cp/.claude"
cat > "$_repo_cp/.claude/dso-config.conf" <<'CONF'
paths.app_dir=myapp
paths.src_dir=src
paths.test_dir=tests
CONF

_cfg_output=""
_cfg_exit=0
_cfg_output=$(
    cd "$_repo_cp" &&
    unset WORKFLOW_CONFIG_FILE 2>/dev/null || true
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    unset _CONFIG_PATHS_LOADED 2>/dev/null || true
    bash -c "
        source '$CONFIG_PATHS'
        echo \"\$CFG_APP_DIR\"
    " 2>&1
) || _cfg_exit=$?

assert_eq "test_e2e_config_paths_reads_from_dot_claude: exit 0" "0" "$_cfg_exit"
assert_eq "test_e2e_config_paths_reads_from_dot_claude: CFG_APP_DIR=myapp" "myapp" "$_cfg_output"

# Also verify paths.src_dir and paths.test_dir are read correctly
_cfg_src_output=""
_cfg_src_exit=0
_cfg_src_output=$(
    cd "$_repo_cp" &&
    unset WORKFLOW_CONFIG_FILE 2>/dev/null || true
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    unset _CONFIG_PATHS_LOADED 2>/dev/null || true
    bash -c "
        source '$CONFIG_PATHS'
        echo \"\$CFG_SRC_DIR\"
    " 2>&1
) || _cfg_src_exit=$?

assert_eq "test_e2e_config_paths_reads_from_dot_claude: CFG_SRC_DIR=src exit 0" "0" "$_cfg_src_exit"
assert_eq "test_e2e_config_paths_reads_from_dot_claude: CFG_SRC_DIR=src" "src" "$_cfg_src_output"

assert_pass_if_clean "test_e2e_config_paths_reads_from_dot_claude"

# ── test_e2e_shim_resolves_plugin_root ────────────────────────────────────────
# Given a temp git repo with .claude/dso-config.conf containing
# dso.plugin_root=/some/path, running the shim (via source --lib) sets
# DSO_ROOT=/some/path.
_snapshot_fail
_repo_shim="$(_make_temp_repo)"
mkdir -p "$_repo_shim/.claude"
# Use the actual plugin dir as a valid path for testing
_fake_plugin_root="$DSO_PLUGIN_DIR"
cat > "$_repo_shim/.claude/dso-config.conf" <<CONF
dso.plugin_root=${_fake_plugin_root}
CONF

_shim_output=""
_shim_exit=0
_shim_output=$(
    cd "$_repo_shim" &&
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash -c "
        source '$SHIM' --lib
        echo \"\$DSO_ROOT\"
    " 2>&1
) || _shim_exit=$?

assert_eq "test_e2e_shim_resolves_plugin_root: exit 0" "0" "$_shim_exit"
assert_eq "test_e2e_shim_resolves_plugin_root: DSO_ROOT set from .claude/dso-config.conf" "$_fake_plugin_root" "$_shim_output"

assert_pass_if_clean "test_e2e_shim_resolves_plugin_root"

# ── test_e2e_shim_no_config_exits_nonzero ────────────────────────────────────
# When no config file exists and CLAUDE_PLUGIN_ROOT is unset, the shim
# exits non-zero with a helpful error message.
_snapshot_fail
_repo_shim_fail="$(_make_temp_repo)"

_shim_fail_output=""
_shim_fail_exit=0
_shim_fail_output=$(
    cd "$_repo_shim_fail" &&
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    bash "$SHIM" some-command 2>&1
) || _shim_fail_exit=$?

if [[ "$_shim_fail_exit" -ne 0 ]]; then
    _actual_shim_fail_exit="nonzero"
else
    _actual_shim_fail_exit="zero"
fi
assert_eq "test_e2e_shim_no_config_exits_nonzero: exits nonzero" "nonzero" "$_actual_shim_fail_exit"
assert_contains "test_e2e_shim_no_config_exits_nonzero: error mentions dso-config.conf" "dso-config.conf" "$_shim_fail_output"

assert_pass_if_clean "test_e2e_shim_no_config_exits_nonzero"

# ── test_e2e_validate_sh_reads_commands ──────────────────────────────────────
# Given a temp git repo with .claude/dso-config.conf containing
# commands.test=echo test, validate.sh reads that value correctly
# (integration with CONFIG_FILE env var for test isolation).
_snapshot_fail
_repo_val="$(_make_temp_repo)"
mkdir -p "$_repo_val/.claude"
cat > "$_repo_val/.claude/dso-config.conf" <<'CONF'
commands.test=echo run-tests
commands.lint=echo run-lint
CONF

_val_output=""
_val_exit=0
_val_output=$(
    cd "$_repo_val" &&
    unset WORKFLOW_CONFIG_FILE 2>/dev/null || true
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
    CONFIG_FILE="$_repo_val/.claude/dso-config.conf" \
        bash "$READ_CONFIG" "commands.test" "$_repo_val/.claude/dso-config.conf" 2>&1
) || _val_exit=$?

assert_eq "test_e2e_validate_sh_reads_commands: exit 0" "0" "$_val_exit"
assert_eq "test_e2e_validate_sh_reads_commands: reads commands.test" "echo run-tests" "$_val_output"

# Also verify commands.lint is readable
_val_lint_output=""
_val_lint_exit=0
_val_lint_output=$(
    bash "$READ_CONFIG" "commands.lint" "$_repo_val/.claude/dso-config.conf" 2>&1
) || _val_lint_exit=$?

assert_eq "test_e2e_validate_sh_reads_commands: reads commands.lint exit 0" "0" "$_val_lint_exit"
assert_eq "test_e2e_validate_sh_reads_commands: reads commands.lint value" "echo run-lint" "$_val_lint_output"

assert_pass_if_clean "test_e2e_validate_sh_reads_commands"

# ── test_e2e_workflow_config_file_env_overrides ───────────────────────────────
# WORKFLOW_CONFIG_FILE env var overrides .claude/dso-config.conf resolution
# (backward compat for test isolation across the whole chain).
_snapshot_fail
_repo_env="$(_make_temp_repo)"
mkdir -p "$_repo_env/.claude"
cat > "$_repo_env/.claude/dso-config.conf" <<'CONF'
paths.app_dir=from-dso-config
CONF

_env_override_file="$(mktemp)"
_e2e_tmpdirs+=("$_env_override_file")
cat > "$_env_override_file" <<'CONF'
paths.app_dir=from-env-override
CONF

_env_output=""
_env_exit=0
_env_output=$(
    cd "$_repo_env" &&
    WORKFLOW_CONFIG_FILE="$_env_override_file" \
        bash "$READ_CONFIG" "paths.app_dir" 2>&1
) || _env_exit=$?

assert_eq "test_e2e_workflow_config_file_env_overrides: exit 0" "0" "$_env_exit"
assert_eq "test_e2e_workflow_config_file_env_overrides: env var wins over .claude/dso-config.conf" "from-env-override" "$_env_output"

assert_pass_if_clean "test_e2e_workflow_config_file_env_overrides"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
