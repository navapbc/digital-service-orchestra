#!/usr/bin/env bash
# tests/scripts/test-validate-config-driven.sh
# TDD tests verifying that validate.sh reads commands from config
# instead of hardcoding make calls.
#
# Tests:
#   test_validate_reads_commands_from_config — no hardcoded make in run_check invocations
#   test_validate_defaults_match_current_make_targets — fallback defaults match workflow-config.conf
#   test_validate_sources_read_config — validate.sh sources read-config.sh
#   test_new_config_keys_exist — commands.syntax_check etc. exist in workflow-config.conf
#   test_app_dir_uses_config — APP_DIR resolution uses config, not hardcoded app check
#
# Usage: bash tests/scripts/test-validate-config-driven.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$PLUGIN_ROOT/scripts/validate.sh"

# Create an inline fixture config instead of depending on project config
CONFIG_FILE="$(mktemp)"
trap 'rm -f "$CONFIG_FILE"' EXIT
cat > "$CONFIG_FILE" <<'FIXTURE'
commands.syntax_check=make syntax-check
commands.lint_ruff=make lint-ruff
commands.lint_mypy=make lint-mypy
commands.test_plugin=make test-plugin
FIXTURE

echo "=== test-validate-config-driven.sh ==="

# ── test_validate_reads_commands_from_config ──────────────────────────────
# No hardcoded make calls in run_check invocations (outside comments and fallback defaults)
_snapshot_fail

# Get non-comment lines with run_check that contain a bare make call
# (not inside a fallback/default expression like ${VAR:-make ...})
hardcoded_make=$(
    grep -v '^\s*#' "$VALIDATE_SH" \
    | grep 'run_check.*make ' \
    | grep -v 'fallback\|default\|:-' \
    || true
)

assert_eq "no hardcoded make in run_check calls" "" "$hardcoded_make"

assert_pass_if_clean "test_validate_reads_commands_from_config"

# ── test_validate_sources_read_config ─────────────────────────────────────
# validate.sh should reference read-config.sh to load config values
_snapshot_fail

has_read_config=$(grep -c 'read-config.sh' "$VALIDATE_SH" || true)
assert_ne "validate.sh references read-config.sh" "0" "$has_read_config"

assert_pass_if_clean "test_validate_sources_read_config"

# ── test_new_config_keys_exist ────────────────────────────────────────────
# New command keys must exist in workflow-config.conf
_snapshot_fail

for key in commands.syntax_check commands.lint_ruff commands.lint_mypy commands.test_plugin; do
    found=$(grep -c "^${key}=" "$CONFIG_FILE" || true)
    assert_ne "config key $key exists in workflow-config.conf" "0" "$found"
done

assert_pass_if_clean "test_new_config_keys_exist"

# ── test_validate_defaults_match_current_make_targets ─────────────────────
# The fallback defaults in validate.sh should match what's in workflow-config.conf
_snapshot_fail

# Read config values
syntax_check=$(grep "^commands.syntax_check=" "$CONFIG_FILE" | cut -d= -f2-)
lint_ruff=$(grep "^commands.lint_ruff=" "$CONFIG_FILE" | cut -d= -f2-)
lint_mypy=$(grep "^commands.lint_mypy=" "$CONFIG_FILE" | cut -d= -f2-)
test_plugin=$(grep "^commands.test_plugin=" "$CONFIG_FILE" | cut -d= -f2-)

assert_eq "commands.syntax_check value" "make syntax-check" "$syntax_check"
assert_eq "commands.lint_ruff value" "make lint-ruff" "$lint_ruff"
assert_eq "commands.lint_mypy value" "make lint-mypy" "$lint_mypy"
assert_eq "commands.test_plugin value" "make test-plugin" "$test_plugin"

assert_pass_if_clean "test_validate_defaults_match_current_make_targets"

# ── test_app_dir_uses_config ──────────────────────────────────────────────
# validate.sh APP_DIR resolution should use config, not hardcoded 'if -d app'
_snapshot_fail

hardcoded_app_check=$(
    grep -v '^\s*#' "$VALIDATE_SH" \
    | grep -E 'if.*-d.*app"' \
    || true
)

assert_eq "no hardcoded app dir check" "" "$hardcoded_app_check"

assert_pass_if_clean "test_app_dir_uses_config"

# ── test_workflow_config_has_all_validate_keys ────────────────────────────
# The real workflow-config.conf must define all command keys that validate.sh
# reads, so running validate.sh from the DSO repo root works without make.
_snapshot_fail

REAL_CONFIG="$PLUGIN_ROOT/workflow-config.conf"

for key in commands.syntax_check commands.lint_ruff commands.lint_mypy commands.test_plugin; do
    found=$(grep -c "^${key}=" "$REAL_CONFIG" || true)
    assert_ne "workflow-config.conf has key $key" "0" "$found"
done

assert_pass_if_clean "test_workflow_config_has_all_validate_keys"

# ── test_validate_handles_missing_app_dir ────────────────────────────────
# validate.sh must not fail with "cd: app: No such file" when APP_DIR
# does not exist (e.g. DSO plugin repo has no app/ subdirectory).
# The guard in validate.sh falls back to REPO_ROOT when APP_DIR is absent.
_snapshot_fail

found=$(grep -c '"\$APP_DIR" \]; then' "$VALIDATE_SH" || true)
assert_ne "validate_sh_guards_cd_to_app_dir" "0" "$found"

assert_pass_if_clean "test_validate_handles_missing_app_dir"

print_summary
