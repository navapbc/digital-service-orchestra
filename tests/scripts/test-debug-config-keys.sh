#!/usr/bin/env bash
# tests/scripts/test-debug-config-keys.sh
# Structural metadata validation of dso-config.conf debug namespace keys.
#
# Verifies that .claude/dso-config.conf contains:
#   1. The debug.max_fix_validate_cycles key
#   2. The key has default value 3
#
# Test status:
#   Both tests are RED until config task 9caf-454f adds the key.
#
# Exemption: structural metadata validation of config file — not executable code.
#
# Usage: bash tests/scripts/test-debug-config-keys.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PLUGIN_ROOT/.claude/dso-config.conf"
READ_CONFIG="$PLUGIN_ROOT/plugins/dso/scripts/read-config.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-config-keys.sh ==="

# ============================================================
# test_max_fix_validate_cycles_key_exists
# .claude/dso-config.conf must contain the key
# debug.max_fix_validate_cycles.
# RED: key not present until config task 9caf-454f runs.
# ============================================================
test_max_fix_validate_cycles_key_exists() {
    local key_found="missing"

    if grep -qE '^debug\.max_fix_validate_cycles=' "$CONFIG_FILE" 2>/dev/null; then
        key_found="found"
    fi

    assert_eq "test_max_fix_validate_cycles_key_exists: debug.max_fix_validate_cycles key present in dso-config.conf" "found" "$key_found"
}

# ============================================================
# test_max_fix_validate_cycles_default_value
# The debug.max_fix_validate_cycles key must have value 3
# (the documented default for maximum fix→validate cycles).
# RED: key not present until config task 9caf-454f runs.
# ============================================================
test_max_fix_validate_cycles_default_value() {
    local actual_value=""

    # Try read-config.sh first (canonical reader)
    if [[ -x "$READ_CONFIG" ]]; then
        actual_value=$("$READ_CONFIG" "debug.max_fix_validate_cycles" "$CONFIG_FILE" 2>/dev/null)
    fi

    # Fall back to direct grep if read-config.sh is unavailable or returned empty
    if [[ -z "$actual_value" ]]; then
        actual_value=$(grep -E '^debug\.max_fix_validate_cycles=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    fi

    assert_eq "test_max_fix_validate_cycles_default_value: debug.max_fix_validate_cycles default value is 3" "3" "$actual_value"
}

# ============================================================
# Run all tests
# ============================================================
test_max_fix_validate_cycles_key_exists
test_max_fix_validate_cycles_default_value

print_summary
