#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-fallback-prompts.sh
# TDD tests for fallback prompt templates (batch 1):
#   test_fix_unit.md, mechanical_fix.md, code_simplify.md, security_audit.md
#
# Usage: bash lockpick-workflow/tests/scripts/test-fallback-prompts.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until prompt files are created.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
PROMPTS_DIR="$PLUGIN_ROOT/prompts/fallback"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-fallback-prompts.sh ==="

# List of prompts this test covers
PROMPTS=(test_fix_unit mechanical_fix code_simplify security_audit)

# ── test_prompt_files_exist ──────────────────────────────────────────────────
# Each prompt file must exist at prompts/fallback/<category>.md
for prompt in "${PROMPTS[@]}"; do
    _snapshot_fail
    if [[ -f "$PROMPTS_DIR/$prompt.md" ]]; then
        actual_exists="exists"
    else
        actual_exists="missing"
    fi
    assert_eq "test_prompt_file_exists: $prompt.md" "exists" "$actual_exists"
    assert_pass_if_clean "test_prompt_file_exists: $prompt.md"
done

# ── test_universal_context_placeholder ───────────────────────────────────────
# All prompts must contain {context} (universal contract)
for prompt in "${PROMPTS[@]}"; do
    _snapshot_fail
    if [[ -f "$PROMPTS_DIR/$prompt.md" ]] && grep -q '{context}' "$PROMPTS_DIR/$prompt.md"; then
        actual_ctx="present"
    else
        actual_ctx="missing"
    fi
    assert_eq "test_universal_context: $prompt.md contains {context}" "present" "$actual_ctx"
    assert_pass_if_clean "test_universal_context: $prompt.md contains {context}"
done

# ── test_category_specific_placeholders ──────────────────────────────────────

# test_fix_unit.md must contain {test_command} and {exit_code}
_snapshot_fail
if [[ -f "$PROMPTS_DIR/test_fix_unit.md" ]] \
    && grep -q '{test_command}' "$PROMPTS_DIR/test_fix_unit.md" \
    && grep -q '{exit_code}' "$PROMPTS_DIR/test_fix_unit.md"; then
    actual_tfu="present"
else
    actual_tfu="missing"
fi
assert_eq "test_fix_unit placeholders: {test_command}, {exit_code}" "present" "$actual_tfu"
assert_pass_if_clean "test_fix_unit placeholders: {test_command}, {exit_code}"

# test_fix_unit.md must also contain {stderr_tail} and {changed_files}
_snapshot_fail
if [[ -f "$PROMPTS_DIR/test_fix_unit.md" ]] \
    && grep -q '{stderr_tail}' "$PROMPTS_DIR/test_fix_unit.md" \
    && grep -q '{changed_files}' "$PROMPTS_DIR/test_fix_unit.md"; then
    actual_tfu2="present"
else
    actual_tfu2="missing"
fi
assert_eq "test_fix_unit placeholders: {stderr_tail}, {changed_files}" "present" "$actual_tfu2"
assert_pass_if_clean "test_fix_unit placeholders: {stderr_tail}, {changed_files}"

# mechanical_fix.md must contain {lint_command} and {exit_code}
_snapshot_fail
if [[ -f "$PROMPTS_DIR/mechanical_fix.md" ]] \
    && grep -q '{lint_command}' "$PROMPTS_DIR/mechanical_fix.md" \
    && grep -q '{exit_code}' "$PROMPTS_DIR/mechanical_fix.md"; then
    actual_mf="present"
else
    actual_mf="missing"
fi
assert_eq "mechanical_fix placeholders: {lint_command}, {exit_code}" "present" "$actual_mf"
assert_pass_if_clean "mechanical_fix placeholders: {lint_command}, {exit_code}"

# mechanical_fix.md must also contain {stderr_tail} and {changed_files}
_snapshot_fail
if [[ -f "$PROMPTS_DIR/mechanical_fix.md" ]] \
    && grep -q '{stderr_tail}' "$PROMPTS_DIR/mechanical_fix.md" \
    && grep -q '{changed_files}' "$PROMPTS_DIR/mechanical_fix.md"; then
    actual_mf2="present"
else
    actual_mf2="missing"
fi
assert_eq "mechanical_fix placeholders: {stderr_tail}, {changed_files}" "present" "$actual_mf2"
assert_pass_if_clean "mechanical_fix placeholders: {stderr_tail}, {changed_files}"

# code_simplify.md must contain {target_files} and {complexity_metric}
_snapshot_fail
if [[ -f "$PROMPTS_DIR/code_simplify.md" ]] \
    && grep -q '{target_files}' "$PROMPTS_DIR/code_simplify.md" \
    && grep -q '{complexity_metric}' "$PROMPTS_DIR/code_simplify.md"; then
    actual_cs="present"
else
    actual_cs="missing"
fi
assert_eq "code_simplify placeholders: {target_files}, {complexity_metric}" "present" "$actual_cs"
assert_pass_if_clean "code_simplify placeholders: {target_files}, {complexity_metric}"

# security_audit.md must contain {target_files} and {audit_scope}
_snapshot_fail
if [[ -f "$PROMPTS_DIR/security_audit.md" ]] \
    && grep -q '{target_files}' "$PROMPTS_DIR/security_audit.md" \
    && grep -q '{audit_scope}' "$PROMPTS_DIR/security_audit.md"; then
    actual_sa="present"
else
    actual_sa="missing"
fi
assert_eq "security_audit placeholders: {target_files}, {audit_scope}" "present" "$actual_sa"
assert_pass_if_clean "security_audit placeholders: {target_files}, {audit_scope}"

# ── test_verify_section_present ──────────────────────────────────────────────
# Each prompt must have a Verify: section
for prompt in "${PROMPTS[@]}"; do
    _snapshot_fail
    if [[ -f "$PROMPTS_DIR/$prompt.md" ]] && grep -q 'Verify:' "$PROMPTS_DIR/$prompt.md"; then
        actual_verify="present"
    else
        actual_verify="missing"
    fi
    assert_eq "test_verify_section: $prompt.md has Verify:" "present" "$actual_verify"
    assert_pass_if_clean "test_verify_section: $prompt.md has Verify:"
done

# ── test_minimum_content_length ──────────────────────────────────────────────
# Each prompt must have >= 10 lines of content
for prompt in "${PROMPTS[@]}"; do
    _snapshot_fail
    if [[ -f "$PROMPTS_DIR/$prompt.md" ]]; then
        line_count=$(wc -l < "$PROMPTS_DIR/$prompt.md" | tr -d ' ')
        if [[ "$line_count" -ge 10 ]]; then
            actual_len="sufficient"
        else
            actual_len="too_short ($line_count lines)"
        fi
    else
        actual_len="too_short (file missing)"
    fi
    assert_eq "test_min_content: $prompt.md >= 10 lines" "sufficient" "$actual_len"
    assert_pass_if_clean "test_min_content: $prompt.md >= 10 lines"
done

print_summary
