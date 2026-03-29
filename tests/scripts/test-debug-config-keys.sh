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
# test_max_cycles_zero_skips_loop
# SKILL.md documents that value=0 (i.e., <= 0) means skip the
# validation loop entirely and proceed directly to Phase 8.
# ============================================================
test_max_cycles_zero_skips_loop() {
    local skill_md="$PLUGIN_ROOT/plugins/dso/skills/debug-everything/SKILL.md"
    local found="missing"

    if grep -qE '<= 0|skip validation loop entirely' "$skill_md" 2>/dev/null; then
        found="documented"
    fi

    assert_eq "test_max_cycles_zero_skips_loop: SKILL.md documents <= 0 skips validation loop" "documented" "$found"
}

# ============================================================
# test_max_cycles_negative_defaults
# SKILL.md documents that negative values (covered by <= 0 rule)
# result in MAX_FIX_VALIDATE_CYCLES=0 (skip loop). The negative
# case is subsumed by the <= 0 rule documented in SKILL.md.
# ============================================================
test_max_cycles_negative_defaults() {
    local skill_md="$PLUGIN_ROOT/plugins/dso/skills/debug-everything/SKILL.md"
    local found="missing"

    # SKILL.md uses "<= 0" which covers negative values
    if grep -qE 'Value.*<= 0' "$skill_md" 2>/dev/null; then
        found="documented"
    fi

    assert_eq "test_max_cycles_negative_defaults: SKILL.md documents <= 0 rule covering negative values" "documented" "$found"
}

# ============================================================
# test_max_cycles_non_numeric_defaults
# SKILL.md documents that non-numeric values default to 3
# with a warning message.
# ============================================================
test_max_cycles_non_numeric_defaults() {
    local skill_md="$PLUGIN_ROOT/plugins/dso/skills/debug-everything/SKILL.md"
    local found="missing"

    if grep -qE 'Non-numeric.*default.*3|not numeric.*defaulting to 3' "$skill_md" 2>/dev/null; then
        found="documented"
    fi

    assert_eq "test_max_cycles_non_numeric_defaults: SKILL.md documents non-numeric defaults to 3 with warning" "documented" "$found"
}

# ============================================================
# test_max_cycles_capped_at_10
# SKILL.md documents that values > 10 are capped at 10
# with a warning message.
# ============================================================
test_max_cycles_capped_at_10() {
    local skill_md="$PLUGIN_ROOT/plugins/dso/skills/debug-everything/SKILL.md"
    local found="missing"

    if grep -qE 'capping at 10|exceeds cap of 10|Value.*> 10.*MAX_FIX_VALIDATE_CYCLES=10' "$skill_md" 2>/dev/null; then
        found="documented"
    fi

    assert_eq "test_max_cycles_capped_at_10: SKILL.md documents values > 10 capped at 10 with warning" "documented" "$found"
}

# ============================================================
# Run all tests
# ============================================================
test_max_fix_validate_cycles_key_exists
test_max_fix_validate_cycles_default_value
test_max_cycles_zero_skips_loop
test_max_cycles_negative_defaults
test_max_cycles_non_numeric_defaults
test_max_cycles_capped_at_10

print_summary
