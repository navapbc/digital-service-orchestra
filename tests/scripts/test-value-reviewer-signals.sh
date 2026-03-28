#!/usr/bin/env bash
# tests/scripts/test-value-reviewer-signals.sh
# TDD tests for value reviewer validation_signal content.
#
# Tests:
#  (a) test_no_usability_testing   — value.md must NOT contain 'usability testing'
#  (b) test_no_support_ticket_vol  — value.md must NOT contain 'support ticket volume decrease'
#  (c) test_no_ab_tests            — value.md must NOT contain 'A/B tests'
#  (d) test_has_dogfooding         — value.md MUST contain 'dogfooding'
#  (e) test_has_before_after       — value.md MUST contain 'before/after'
#  (f) test_has_operational_metrics — value.md MUST contain 'operational metrics'
#
# Usage: bash tests/scripts/test-value-reviewer-signals.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED STATE: These tests currently fail because value.md still contains external
# validation signals ('usability testing', 'support ticket volume decrease', 'A/B tests')
# and does not yet contain the internal signals ('dogfooding', 'before/after',
# 'operational metrics'). They will pass (GREEN) after value.md is updated.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALUE_MD="$PLUGIN_ROOT/plugins/dso/skills/shared/docs/reviewers/value.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-value-reviewer-signals.sh ==="

# ── test_no_usability_testing ─────────────────────────────────────────────────
# (a) value.md must NOT contain 'usability testing' (external validation signal)
test_no_usability_testing() {
    _snapshot_fail
    local _content
    _content=$(cat "$VALUE_MD")
    local _found=0
    if echo "$_content" | grep -qF 'usability testing'; then
        _found=1
    fi
    assert_eq "test_no_usability_testing: value.md must NOT contain 'usability testing'" "0" "$_found"
    assert_pass_if_clean "test_no_usability_testing"
}

# ── test_no_support_ticket_vol ────────────────────────────────────────────────
# (b) value.md must NOT contain 'support ticket volume decrease' (external signal)
test_no_support_ticket_vol() {
    _snapshot_fail
    local _content
    _content=$(cat "$VALUE_MD")
    local _found=0
    if echo "$_content" | grep -qF 'support ticket volume decrease'; then
        _found=1
    fi
    assert_eq "test_no_support_ticket_vol: value.md must NOT contain 'support ticket volume decrease'" "0" "$_found"
    assert_pass_if_clean "test_no_support_ticket_vol"
}

# ── test_no_ab_tests ──────────────────────────────────────────────────────────
# (c) value.md must NOT contain 'A/B tests' (external validation signal)
test_no_ab_tests() {
    _snapshot_fail
    local _content
    _content=$(cat "$VALUE_MD")
    local _found=0
    if echo "$_content" | grep -qF 'A/B tests'; then
        _found=1
    fi
    assert_eq "test_no_ab_tests: value.md must NOT contain 'A/B tests'" "0" "$_found"
    assert_pass_if_clean "test_no_ab_tests"
}

# ── test_has_dogfooding ───────────────────────────────────────────────────────
# (d) value.md MUST contain 'dogfooding' (internal validation signal)
test_has_dogfooding() {
    _snapshot_fail
    local _content
    _content=$(cat "$VALUE_MD")
    local _found=0
    if echo "$_content" | grep -qF 'dogfooding'; then
        _found=1
    fi
    assert_eq "test_has_dogfooding: value.md MUST contain 'dogfooding'" "1" "$_found"
    assert_pass_if_clean "test_has_dogfooding"
}

# ── test_has_before_after ─────────────────────────────────────────────────────
# (e) value.md MUST contain 'before/after' (internal validation signal)
test_has_before_after() {
    _snapshot_fail
    local _content
    _content=$(cat "$VALUE_MD")
    local _found=0
    if echo "$_content" | grep -qF 'before/after'; then
        _found=1
    fi
    assert_eq "test_has_before_after: value.md MUST contain 'before/after'" "1" "$_found"
    assert_pass_if_clean "test_has_before_after"
}

# ── test_has_operational_metrics ──────────────────────────────────────────────
# (f) value.md MUST contain 'operational metrics' (internal validation signal)
test_has_operational_metrics() {
    _snapshot_fail
    local _content
    _content=$(cat "$VALUE_MD")
    local _found=0
    if echo "$_content" | grep -qF 'operational metrics'; then
        _found=1
    fi
    assert_eq "test_has_operational_metrics: value.md MUST contain 'operational metrics'" "1" "$_found"
    assert_pass_if_clean "test_has_operational_metrics"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_no_usability_testing
test_no_support_ticket_vol
test_no_ab_tests
test_has_dogfooding
test_has_before_after
test_has_operational_metrics

print_summary
