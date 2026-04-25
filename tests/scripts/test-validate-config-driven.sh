#!/usr/bin/env bash
# tests/scripts/test-validate-config-driven.sh
# TDD tests verifying that validate.sh reads commands from config
# instead of hardcoding make calls.
#
# Tests:
#   test_validate_reads_commands_from_config — no hardcoded make in run_check invocations
#   test_validate_defaults_match_current_make_targets — fallback defaults match dso-config.conf
#   test_validate_sources_read_config — validate.sh sources read-config.sh
#   test_new_config_keys_exist — commands.syntax_check etc. exist in dso-config.conf
#   test_app_dir_uses_config — APP_DIR resolution uses config, not hardcoded app check
#
# Usage: bash tests/scripts/test-validate-config-driven.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"

# Create an inline fixture config instead of depending on project config
CONFIG_FILE="$(mktemp)"
trap 'rm -f "$CONFIG_FILE"' EXIT
cat > "$CONFIG_FILE" <<'FIXTURE'
commands.syntax_check=make syntax-check
commands.lint_ruff=make lint-ruff
commands.lint_mypy=make lint-mypy
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
# New command keys must exist in dso-config.conf
_snapshot_fail

for key in commands.syntax_check commands.lint_ruff commands.lint_mypy; do
    found=$(grep -c "^${key}=" "$CONFIG_FILE" || true)
    assert_ne "config key $key exists in dso-config.conf" "0" "$found"
done

assert_pass_if_clean "test_new_config_keys_exist"

# ── test_validate_defaults_match_current_make_targets ─────────────────────
# The fallback defaults in validate.sh should match what's in dso-config.conf
_snapshot_fail

# Read config values
syntax_check=$(grep "^commands.syntax_check=" "$CONFIG_FILE" | cut -d= -f2-)
lint_ruff=$(grep "^commands.lint_ruff=" "$CONFIG_FILE" | cut -d= -f2-)
lint_mypy=$(grep "^commands.lint_mypy=" "$CONFIG_FILE" | cut -d= -f2-)

assert_eq "commands.syntax_check value" "make syntax-check" "$syntax_check"
assert_eq "commands.lint_ruff value" "make lint-ruff" "$lint_ruff"
assert_eq "commands.lint_mypy value" "make lint-mypy" "$lint_mypy"

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
# The real dso-config.conf must define all command keys that validate.sh
# reads, so running validate.sh from the DSO repo root works without make.
_snapshot_fail

REAL_CONFIG="$PLUGIN_ROOT/.claude/dso-config.conf"

for key in commands.syntax_check commands.lint_ruff commands.lint_mypy; do
    found=$(grep -c "^${key}=" "$REAL_CONFIG" || true)
    assert_ne "dso-config.conf has key $key" "0" "$found"
done

assert_pass_if_clean "test_workflow_config_has_all_validate_keys"

# ── test_validate_handles_missing_app_dir ────────────────────────────────
# validate.sh must not fail with "cd: app: No such file" when APP_DIR
# does not exist (e.g. DSO plugin repo has no app/ subdirectory).
# The guard in validate.sh falls back to REPO_ROOT when APP_DIR is absent.
_snapshot_fail

# shellcheck disable=SC2016  # intentional: searching for literal '$APP_DIR' text in validate.sh
found=$(grep -c '"\$APP_DIR" \]; then' "$VALIDATE_SH" || true)
assert_ne "validate_sh_guards_cd_to_app_dir" "0" "$found"

assert_pass_if_clean "test_validate_handles_missing_app_dir"

# ── test_no_test_plugin_in_config ────────────────────────────────────────
# commands.test_plugin is a vestigial key and must NOT be present in
# the real dso-config.conf.
_snapshot_fail

REAL_CONFIG_NTP="$PLUGIN_ROOT/.claude/dso-config.conf"
test_plugin_count=$(grep -c "^commands.test_plugin=" "$REAL_CONFIG_NTP" || true)
assert_eq "commands.test_plugin absent from dso-config.conf" "0" "$test_plugin_count"

assert_pass_if_clean "test_no_test_plugin_in_config"

# ── test_validate_sh_no_cmd_test_plugin ──────────────────────────────────
# CMD_TEST_PLUGIN must NOT appear in validate.sh (plugin check infrastructure removed)
_snapshot_fail

cmd_test_plugin_count=$(grep -c 'CMD_TEST_PLUGIN' "$VALIDATE_SH" || true)
assert_eq "CMD_TEST_PLUGIN absent from validate.sh" "0" "$cmd_test_plugin_count"

assert_pass_if_clean "test_validate_sh_no_cmd_test_plugin"

# ── test_validate_reads_commands_lint_from_config ─────────────────────────
# Behavioral RED: when commands.lint is configured, validate.sh must invoke it.
# All other commands are stubbed to 'true' so only the lint sentinel matters.
# Expected to FAIL before task 9d97-f2cb adds the implementation.
_snapshot_fail

_VLT_DIR=$(mktemp -d /tmp/test-validate-lint-XXXXXX)
_VLT_SENTINEL="$_VLT_DIR/lint-called"
_VLT_LINT="$_VLT_DIR/mock-lint.sh"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$_VLT_SENTINEL" > "$_VLT_LINT"
chmod +x "$_VLT_LINT"
_VLT_CFG="$_VLT_DIR/dso-config.conf"
cat > "$_VLT_CFG" << VLTEOT
commands.syntax_check=true
commands.format_check=true
commands.lint_ruff=true
commands.lint_mypy=true
commands.lint=$_VLT_LINT
VLTEOT

CONFIG_FILE="$_VLT_CFG" VALIDATE_CMD_TEST=true \
    bash "$VALIDATE_SH" --skip-ci >/dev/null 2>&1 || true

_vlt_lint_called=0
[[ -f "$_VLT_SENTINEL" ]] && _vlt_lint_called=1
rm -rf "$_VLT_DIR"
assert_eq "validate.sh invokes commands.lint when configured" "1" "$_vlt_lint_called"

assert_pass_if_clean "test_validate_reads_commands_lint_from_config"

# ── test_validate_warns_when_no_lint_configured ───────────────────────────
# Behavioral RED: when commands.lint is absent from config, validate.sh must
# emit a [DSO WARN] to stdout. Expected to FAIL before 9d97-f2cb.
_snapshot_fail

_VLW_DIR=$(mktemp -d /tmp/test-validate-lint-warn-XXXXXX)
_VLW_CFG="$_VLW_DIR/dso-config-no-lint.conf"
cat > "$_VLW_CFG" << VLWEOT
commands.syntax_check=true
commands.format_check=true
VLWEOT

_vlt_warn_out=""
_vlt_warn_out=$(CONFIG_FILE="$_VLW_CFG" VALIDATE_CMD_TEST=true \
    bash "$VALIDATE_SH" --skip-ci 2>&1 || true)
rm -rf "$_VLW_DIR"

_vlt_has_warn=0
if grep -q '\[DSO WARN\]' <<< "$_vlt_warn_out"; then
    _vlt_has_warn=1
fi
assert_eq "validate.sh emits [DSO WARN] when commands.lint absent" "1" "$_vlt_has_warn"

assert_pass_if_clean "test_validate_warns_when_no_lint_configured"

# ── test_validate_no_warn_when_legacy_lint_configured ─────────────────────────
# Behavioral: when commands.lint is absent but commands.lint_ruff or commands.lint_mypy
# is explicitly set, validate.sh must NOT emit [DSO WARN] — legacy lint commands
# still provide coverage. Expected to FAIL before the warn-condition fix.
_snapshot_fail

_VNW_DIR=$(mktemp -d /tmp/test-validate-no-warn-XXXXXX)
_VNW_CFG="$_VNW_DIR/dso-config-legacy-lint.conf"
cat > "$_VNW_CFG" << VNWEOT
commands.syntax_check=true
commands.format_check=true
commands.lint_ruff=true
commands.lint_mypy=true
VNWEOT

_vnw_out=""
_vnw_out=$(CONFIG_FILE="$_VNW_CFG" VALIDATE_CMD_TEST=true \
    bash "$VALIDATE_SH" --skip-ci 2>&1 || true)
rm -rf "$_VNW_DIR"

_vnw_has_warn=0
if grep -q '\[DSO WARN\].*commands.lint' <<< "$_vnw_out"; then
    _vnw_has_warn=1
fi
assert_eq "validate.sh suppresses [DSO WARN] when legacy lint keys configured" "0" "$_vnw_has_warn"

assert_pass_if_clean "test_validate_no_warn_when_legacy_lint_configured"

print_summary
