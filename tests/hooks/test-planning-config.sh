#!/usr/bin/env bash
# tests/hooks/test-planning-config.sh
# Behavioral tests for is_external_dep_block_enabled() in planning-config.sh.
#
# Tests verify exit-code semantics for the planning.external_dependency_block_enabled
# config flag: true → exit 0, false → exit 1, absent → exit 1 (default false).
#
# All tests are RED until plugins/dso/hooks/lib/planning-config.sh is created
# (task d5f0-9633). This is intentional — tests must fail before implementation.
#
# Usage: bash tests/hooks/test-planning-config.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
PLANNING_CONFIG_LIB="$DSO_PLUGIN_DIR/hooks/lib/planning-config.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir used by all tests; cleaned up on exit
_TMP_DIR=""
setup() {
    _TMP_DIR=$(mktemp -d)
}
teardown() {
    if [[ -n "${_TMP_DIR:-}" ]]; then
        rm -rf "$_TMP_DIR"
        _TMP_DIR=""
    fi
}
trap teardown EXIT

# ---------------------------------------------------------------------------
# test_flag_true_returns_exit_0
# Config has planning.external_dependency_block_enabled=true
# → is_external_dep_block_enabled must return exit 0
# ---------------------------------------------------------------------------
setup
_CONFIG_FILE="$_TMP_DIR/dso-config.conf"
cat > "$_CONFIG_FILE" <<'CONF'
planning.external_dependency_block_enabled=true
CONF

EXIT_CODE=0
# shellcheck disable=SC2030
(
    export WORKFLOW_CONFIG_FILE="$_CONFIG_FILE"
    source "$PLANNING_CONFIG_LIB"
    is_external_dep_block_enabled
) 2>/dev/null || EXIT_CODE=$?

assert_eq "test_flag_true_returns_exit_0" "0" "$EXIT_CODE"
teardown

# ---------------------------------------------------------------------------
# test_flag_false_returns_exit_1
# Config has planning.external_dependency_block_enabled=false
# → is_external_dep_block_enabled must return exit 1
# ---------------------------------------------------------------------------
setup
_CONFIG_FILE="$_TMP_DIR/dso-config.conf"
cat > "$_CONFIG_FILE" <<'CONF'
planning.external_dependency_block_enabled=false
CONF

EXIT_CODE=0
# shellcheck disable=SC2030,SC2031
(
    export WORKFLOW_CONFIG_FILE="$_CONFIG_FILE"
    source "$PLANNING_CONFIG_LIB"
    is_external_dep_block_enabled
) 2>/dev/null || EXIT_CODE=$?

assert_eq "test_flag_false_returns_exit_1" "1" "$EXIT_CODE"
teardown

# ---------------------------------------------------------------------------
# test_flag_absent_defaults_false
# Config file exists but has no planning.* key
# → is_external_dep_block_enabled must return exit 1 (default: disabled)
# ---------------------------------------------------------------------------
setup
_CONFIG_FILE="$_TMP_DIR/dso-config.conf"
cat > "$_CONFIG_FILE" <<'CONF'
paths.app_dir=app
CONF

EXIT_CODE=0
# shellcheck disable=SC2031
(
    export WORKFLOW_CONFIG_FILE="$_CONFIG_FILE"
    source "$PLANNING_CONFIG_LIB"
    is_external_dep_block_enabled
) 2>/dev/null || EXIT_CODE=$?

assert_eq "test_flag_absent_defaults_false" "1" "$EXIT_CODE"
teardown

print_summary
