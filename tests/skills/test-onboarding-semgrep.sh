#!/usr/bin/env bash
# tests/skills/test-onboarding-semgrep.sh
# RED tests: Verify onboarding SKILL.md includes Semgrep installation
# and test quality configuration steps.
#
# These tests will FAIL (RED) until the onboarding skill is updated to
# include Semgrep tool installation guidance and test quality config steps.
#
# Validates (7 named assertions):
#   test_semgrep_installation_referenced: SKILL.md mentions Semgrep installation
#   test_semgrep_language_detection: SKILL.md ties Semgrep to detected languages
#   test_semgrep_config_generation: SKILL.md describes generating Semgrep config
#   test_test_quality_config_referenced: SKILL.md mentions test quality configuration
#   test_test_quality_coverage_thresholds: SKILL.md does NOT reference coverage_threshold (dead config)
#   test_test_quality_dso_config_key: SKILL.md references a test_quality config key
#   test_semgrep_install_timeout_guard: SKILL.md wraps Semgrep install with timeout 120
#
# Usage: bash tests/skills/test-onboarding-semgrep.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/onboarding/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-onboarding-semgrep.sh ==="

# test_semgrep_installation_referenced: SKILL.md must mention Semgrep installation
# The onboarding skill should guide the user through installing Semgrep
# as a static analysis tool for their detected project languages.
test_semgrep_installation_referenced() {
    _snapshot_fail
    local found="missing"
    # Check for Semgrep installation guidance (case-insensitive to catch Semgrep/semgrep)
    if grep -qi "semgrep" "$SKILL_MD" 2>/dev/null && \
       grep -qi "install" "$SKILL_MD" 2>/dev/null; then
        # Both terms exist — check they appear in the same context (within 10 lines)
        local semgrep_lines install_lines
        semgrep_lines=$(grep -ni "semgrep" "$SKILL_MD" 2>/dev/null | head -5 | cut -d: -f1)
        for sline in $semgrep_lines; do
            local range_start=$((sline > 10 ? sline - 10 : 1))
            local range_end=$((sline + 10))
            if sed -n "${range_start},${range_end}p" "$SKILL_MD" 2>/dev/null | grep -qi "install"; then
                found="found"
                break
            fi
        done
    fi
    assert_eq "test_semgrep_installation_referenced" "found" "$found"
    assert_pass_if_clean "test_semgrep_installation_referenced"
}

# test_semgrep_language_detection: SKILL.md should connect Semgrep config to detected languages
# Onboarding auto-detects project languages; Semgrep rules should be tailored to those languages.
test_semgrep_language_detection() {
    _snapshot_fail
    local found="missing"
    # Look for Semgrep appearing alongside language detection context
    if grep -qi "semgrep" "$SKILL_MD" 2>/dev/null; then
        local semgrep_lines
        semgrep_lines=$(grep -ni "semgrep" "$SKILL_MD" 2>/dev/null | head -5 | cut -d: -f1)
        for sline in $semgrep_lines; do
            local range_start=$((sline > 15 ? sline - 15 : 1))
            local range_end=$((sline + 15))
            local context
            context=$(sed -n "${range_start},${range_end}p" "$SKILL_MD" 2>/dev/null)
            # Check for language-aware configuration context
            if echo "$context" | grep -qiE "language|stack|detect|python|javascript|typescript"; then
                found="found"
                break
            fi
        done
    fi
    assert_eq "test_semgrep_language_detection" "found" "$found"
    assert_pass_if_clean "test_semgrep_language_detection"
}

# test_semgrep_config_generation: SKILL.md should describe generating a Semgrep config file
# The onboarding skill should produce or guide creation of .semgrep.yml or similar config.
test_semgrep_config_generation() {
    _snapshot_fail
    local found="missing"
    if grep -qi "semgrep" "$SKILL_MD" 2>/dev/null; then
        # Look for config file generation context near Semgrep references
        if grep -qiE "\.semgrep|semgrep.*config|semgrep.*rules|semgrep.*yml" "$SKILL_MD" 2>/dev/null; then
            found="found"
        fi
    fi
    assert_eq "test_semgrep_config_generation" "found" "$found"
    assert_pass_if_clean "test_semgrep_config_generation"
}

# test_test_quality_config_referenced: SKILL.md must mention test quality configuration
# Onboarding should include a step for configuring test quality tooling
# (coverage thresholds, mutation testing, quality gates).
test_test_quality_config_referenced() {
    _snapshot_fail
    local found="missing"
    # Check for test quality configuration as a distinct onboarding concern
    if grep -qiE "test.quality|test quality|quality.*config" "$SKILL_MD" 2>/dev/null; then
        found="found"
    fi
    assert_eq "test_test_quality_config_referenced" "found" "$found"
    assert_pass_if_clean "test_test_quality_config_referenced"
}

# test_test_quality_coverage_thresholds: SKILL.md must NOT reference coverage_threshold config key
# coverage_threshold is not consumed by any hook or script (pre-commit-test-quality-gate.sh only
# reads test_quality.enabled and test_quality.tool). Writing a dead config key creates a false
# expectation that coverage enforcement is active. The key must be absent from the skill.
test_test_quality_coverage_thresholds() {
    _snapshot_fail
    local found="absent"
    if grep -qF "coverage_threshold" "$SKILL_MD" 2>/dev/null; then
        found="present"
    fi
    assert_eq "test_test_quality_coverage_thresholds" "absent" "$found"
    assert_pass_if_clean "test_test_quality_coverage_thresholds"
}

# test_test_quality_dso_config_key: SKILL.md should reference a test_quality config key
# The dso-config.conf should gain a test_quality section; onboarding should reference it.
test_test_quality_dso_config_key() {
    _snapshot_fail
    local found="missing"
    if grep -qF "test_quality" "$SKILL_MD" 2>/dev/null; then
        found="found"
    fi
    assert_eq "test_test_quality_dso_config_key" "found" "$found"
    assert_pass_if_clean "test_test_quality_dso_config_key"
}

# test_semgrep_install_timeout_guard: SKILL.md must wrap Semgrep install with timeout 120
# Epic 903c-44fc SC2 required a timeout guard to prevent indefinite hangs during installation.
# This test verifies the guard is present near Semgrep installation code.
test_semgrep_install_timeout_guard() {
    _snapshot_fail
    local found="missing"
    # Look for 'timeout 120' near a Semgrep install invocation
    if grep -qF "timeout 120" "$SKILL_MD" 2>/dev/null; then
        local timeout_lines
        timeout_lines=$(grep -n "timeout 120" "$SKILL_MD" 2>/dev/null | head -5 | cut -d: -f1)
        for tline in $timeout_lines; do
            local range_start=$((tline > 15 ? tline - 15 : 1))
            local range_end=$((tline + 15))
            local context
            context=$(sed -n "${range_start},${range_end}p" "$SKILL_MD" 2>/dev/null)
            if echo "$context" | grep -qi "semgrep\|pip.*install\|brew.*install"; then
                found="found"
                break
            fi
        done
    fi
    assert_eq "test_semgrep_install_timeout_guard" "found" "$found"
    assert_pass_if_clean "test_semgrep_install_timeout_guard"
}

# --- Run all tests ---
test_semgrep_installation_referenced
test_semgrep_language_detection
test_semgrep_config_generation
test_test_quality_config_referenced
test_test_quality_coverage_thresholds
test_test_quality_dso_config_key
test_semgrep_install_timeout_guard

print_summary
