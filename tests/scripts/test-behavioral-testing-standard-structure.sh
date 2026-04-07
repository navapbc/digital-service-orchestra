#!/usr/bin/env bash
# tests/scripts/test-behavioral-testing-standard-structure.sh
# Structural validation for the behavioral testing standard prompt fragment
# (plugins/dso/skills/shared/prompts/behavioral-testing-standard.md).
#
# Tests: file existence, four rules are present, GWT format guidance exists,
#        compliance block schema fields are present, usage section exists.
#
# Usage: bash tests/scripts/test-behavioral-testing-standard-structure.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-behavioral-testing-standard-structure.sh ==="

FRAGMENT="$PLUGIN_ROOT/plugins/dso/skills/shared/prompts/behavioral-testing-standard.md"

# ── test_fragment_file_exists ─────────────────────────────────────────────────
test_fragment_file_exists() {
    local actual
    if [ -f "$FRAGMENT" ] && [ -s "$FRAGMENT" ]; then
        actual="exists_nonempty"
    elif [ -f "$FRAGMENT" ]; then
        actual="exists_empty"
    else
        actual="missing"
    fi
    assert_eq "test_fragment_file_exists: file exists and non-empty" "exists_nonempty" "$actual"
}

# ── test_four_rules_present ───────────────────────────────────────────────────
test_four_rules_present() {
    for rule in "Rule 1" "Rule 2" "Rule 3" "Rule 4"; do
        if grep -q "$rule" "$FRAGMENT"; then
            assert_eq "test_four_rules_present: $rule present" "found" "found"
        else
            assert_eq "test_four_rules_present: $rule present" "found" "missing"
        fi
    done
}

# ── test_gwt_format_guidance ──────────────────────────────────────────────────
test_gwt_format_guidance() {
    local actual="missing"
    if grep -q "Given" "$FRAGMENT" && grep -q "When" "$FRAGMENT" && grep -q "Then" "$FRAGMENT"; then
        actual="found"
    fi
    assert_eq "test_gwt_format_guidance: GWT format guidance present" "found" "$actual"
}

# ── test_compliance_block_fields ──────────────────────────────────────────────
test_compliance_block_fields() {
    for field in "behavioral_testing_compliance" "rule1_coverage_checked" "rule2_gwt_format" "rule3_no_source_reads" "rule4_litmus_passed"; do
        if grep -q "$field" "$FRAGMENT"; then
            assert_eq "test_compliance_block_fields: $field present" "found" "found"
        else
            assert_eq "test_compliance_block_fields: $field present" "found" "missing"
        fi
    done
}

# ── test_usage_section_present ────────────────────────────────────────────────
test_usage_section_present() {
    local actual="missing"
    if grep -q "Usage by Test-Writing Agents" "$FRAGMENT"; then
        actual="found"
    fi
    assert_eq "test_usage_section_present: usage section present" "found" "$actual"
}

# ── run all tests ─────────────────────────────────────────────────────────────
test_fragment_file_exists
test_four_rules_present
test_gwt_format_guidance
test_compliance_block_fields
test_usage_section_present

print_summary
