#!/usr/bin/env bash
# tests/agents/test-red-test-writer.sh
# Verifies the red-test-writer agent definition (plugins/dso/agents/red-test-writer.md)
# contains the expected frontmatter, rejection criteria rubric, and output contract.
#
# Usage: bash tests/agents/test-red-test-writer.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: This test does NOT guard-exit when the agent file is absent.
# Each test fails explicitly when the file is missing (RED phase behavior).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/red-test-writer.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-red-test-writer.sh ==="
echo ""

# ============================================================
# test_frontmatter_has_name_red_test_writer
# YAML frontmatter must declare name: red-test-writer
# ============================================================
test_frontmatter_has_name_red_test_writer() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_frontmatter_has_name_red_test_writer"
        return
    fi
    local _found=0
    if grep -q 'name:.*red-test-writer' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "frontmatter has name: red-test-writer" "1" "$_found"
    assert_pass_if_clean "test_frontmatter_has_name_red_test_writer"
}

# ============================================================
# test_frontmatter_has_model_sonnet
# YAML frontmatter must declare model: sonnet (or claude-sonnet variant)
# ============================================================
test_frontmatter_has_model_sonnet() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_frontmatter_has_model_sonnet"
        return
    fi
    local _found=0
    if grep -qi 'model:.*sonnet' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "frontmatter has model: sonnet" "1" "$_found"
    assert_pass_if_clean "test_frontmatter_has_model_sonnet"
}

# ============================================================
# test_has_rejection_criteria_rubric
# Agent must include a Rejection Criteria Rubric section
# ============================================================
test_has_rejection_criteria_rubric() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_has_rejection_criteria_rubric"
        return
    fi
    local _found=0
    if grep -qi 'Rejection Criteria' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "agent has Rejection Criteria Rubric section" "1" "$_found"
    assert_pass_if_clean "test_has_rejection_criteria_rubric"
}

# ============================================================
# test_rejection_criteria_prohibits_grep_source
# Done Definition 2: agent must explicitly prohibit grepping source files
# ============================================================
test_rejection_criteria_prohibits_grep_source() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_rejection_criteria_prohibits_grep_source"
        return
    fi
    local _found=0
    if grep -qi 'grep.*source\|source.*grep\|grep.*implementation\|implementation.*files' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "agent prohibits grepping source/implementation files" "1" "$_found"
    assert_pass_if_clean "test_rejection_criteria_prohibits_grep_source"
}

# ============================================================
# test_has_output_contract_section
# Agent must include an Output Contract section
# ============================================================
test_has_output_contract_section() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_has_output_contract_section"
        return
    fi
    local _found=0
    if grep -qi 'Output Contract' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "agent has Output Contract section" "1" "$_found"
    assert_pass_if_clean "test_has_output_contract_section"
}

# ============================================================
# test_output_contract_defines_written_format
# Output Contract must define the TEST_RESULT:written format
# ============================================================
test_output_contract_defines_written_format() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_output_contract_defines_written_format"
        return
    fi
    local _found=0
    if grep -q 'TEST_RESULT.*written\|TEST_RESULT:written' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "output contract defines TEST_RESULT:written format" "1" "$_found"
    assert_pass_if_clean "test_output_contract_defines_written_format"
}

# ============================================================
# test_output_contract_defines_rejected_format
# Output Contract must define the TEST_RESULT:rejected format
# ============================================================
test_output_contract_defines_rejected_format() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_output_contract_defines_rejected_format"
        return
    fi
    local _found=0
    if grep -q 'TEST_RESULT.*rejected\|TEST_RESULT:rejected' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "output contract defines TEST_RESULT:rejected format" "1" "$_found"
    assert_pass_if_clean "test_output_contract_defines_rejected_format"
}

# ============================================================
# test_output_contract_written_fields
# The written result format must name TEST_FILE, RED_ASSERTION, BEHAVIORAL_JUSTIFICATION
# ============================================================
test_output_contract_written_fields() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_output_contract_written_fields"
        return
    fi
    local _found_test_file=0
    local _found_red_assertion=0
    local _found_behavioral=0
    if grep -q 'TEST_FILE' "$AGENT_FILE" 2>/dev/null; then _found_test_file=1; fi
    if grep -q 'RED_ASSERTION' "$AGENT_FILE" 2>/dev/null; then _found_red_assertion=1; fi
    if grep -q 'BEHAVIORAL_JUSTIFICATION' "$AGENT_FILE" 2>/dev/null; then _found_behavioral=1; fi
    assert_eq "output contract written result names TEST_FILE" "1" "$_found_test_file"
    assert_eq "output contract written result names RED_ASSERTION" "1" "$_found_red_assertion"
    assert_eq "output contract written result names BEHAVIORAL_JUSTIFICATION" "1" "$_found_behavioral"
    assert_pass_if_clean "test_output_contract_written_fields"
}

# ============================================================
# test_output_contract_rejected_fields
# The rejected result format must name REJECTION_REASON, DESCRIPTION, SUGGESTED_ALTERNATIVE
# ============================================================
test_output_contract_rejected_fields() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_output_contract_rejected_fields"
        return
    fi
    local _found_reason=0
    local _found_desc=0
    local _found_alt=0
    if grep -q 'REJECTION_REASON' "$AGENT_FILE" 2>/dev/null; then _found_reason=1; fi
    if grep -q 'DESCRIPTION' "$AGENT_FILE" 2>/dev/null; then _found_desc=1; fi
    if grep -q 'SUGGESTED_ALTERNATIVE' "$AGENT_FILE" 2>/dev/null; then _found_alt=1; fi
    assert_eq "output contract rejected result names REJECTION_REASON" "1" "$_found_reason"
    assert_eq "output contract rejected result names DESCRIPTION" "1" "$_found_desc"
    assert_eq "output contract rejected result names SUGGESTED_ALTERNATIVE" "1" "$_found_alt"
    assert_pass_if_clean "test_output_contract_rejected_fields"
}

# ============================================================
# test_rejection_reason_enum_defined
# The rejection reason enum must list all 4 defined reasons
# ============================================================
test_rejection_reason_enum_defined() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_rejection_reason_enum_defined"
        return
    fi
    # The 4 rejection reasons per the output contract spec (red-test-writer-output.md)
    local _found_no_observable=0
    local _found_requires_integration=0
    local _found_structural_only=0
    local _found_ambiguous=0
    if grep -qi 'no_observable_behavior' "$AGENT_FILE" 2>/dev/null; then _found_no_observable=1; fi
    if grep -qi 'requires_integration_env' "$AGENT_FILE" 2>/dev/null; then _found_requires_integration=1; fi
    if grep -qi 'structural_only_possible' "$AGENT_FILE" 2>/dev/null; then _found_structural_only=1; fi
    if grep -qi 'ambiguous_spec' "$AGENT_FILE" 2>/dev/null; then _found_ambiguous=1; fi
    assert_eq "rejection reason enum includes no_observable_behavior" "1" "$_found_no_observable"
    assert_eq "rejection reason enum includes requires_integration_env" "1" "$_found_requires_integration"
    assert_eq "rejection reason enum includes structural_only_possible" "1" "$_found_structural_only"
    assert_eq "rejection reason enum includes ambiguous_spec" "1" "$_found_ambiguous"
    assert_pass_if_clean "test_rejection_reason_enum_defined"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "--- test_frontmatter_has_name_red_test_writer ---"
test_frontmatter_has_name_red_test_writer
echo ""

echo "--- test_frontmatter_has_model_sonnet ---"
test_frontmatter_has_model_sonnet
echo ""

echo "--- test_has_rejection_criteria_rubric ---"
test_has_rejection_criteria_rubric
echo ""

echo "--- test_rejection_criteria_prohibits_grep_source ---"
test_rejection_criteria_prohibits_grep_source
echo ""

echo "--- test_has_output_contract_section ---"
test_has_output_contract_section
echo ""

echo "--- test_output_contract_defines_written_format ---"
test_output_contract_defines_written_format
echo ""

echo "--- test_output_contract_defines_rejected_format ---"
test_output_contract_defines_rejected_format
echo ""

echo "--- test_output_contract_written_fields ---"
test_output_contract_written_fields
echo ""

echo "--- test_output_contract_rejected_fields ---"
test_output_contract_rejected_fields
echo ""

echo "--- test_rejection_reason_enum_defined ---"
test_rejection_reason_enum_defined
echo ""

# ============================================================
# test_narrow_exception_excludes_skill_agent_prompt_files
# Bug 9c16-7780: The "Narrow exception" for architectural
# contract verification must NOT apply to skill (.md in
# skills/), agent (.md in agents/), or prompt (.md in
# prompts/) files. These files affect LLM behavior and
# grep-based assertions on them are change-detector tests.
# ============================================================
test_narrow_exception_excludes_skill_agent_prompt_files() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_narrow_exception_excludes_skill_agent_prompt_files"
        return
    fi
    # The narrow exception text must explicitly exclude skill/agent/prompt files
    local _has_exclusion=0
    # The narrow exception must contain explicit exclusion language for
    # skill/agent/prompt files — NOT just mention them as examples of
    # what the exception covers. Look for prohibition language paired
    # with these file categories.
    local _section
    _section=$(sed -n '/[Nn]arrow exception/,/^---$/p' "$AGENT_FILE" 2>/dev/null)
    # Must contain language like "does not apply to skill files" or
    # "does not cover files in skills/" — an actual prohibition, not
    # just mentioning "skill file" as a positive example.
    if echo "$_section" | grep -qiE '(does not (apply|cover|extend)|not acceptable|must not|never applies).*(skill|agent|prompt)' ||
       echo "$_section" | grep -qiE '(skill|agent|prompt).*(does not (apply|cover)|not acceptable|excluded|never)'; then
        _has_exclusion=1
    fi
    assert_eq "narrow exception excludes skill/agent/prompt files (bug 9c16-7780)" "1" "$_has_exclusion"
    assert_pass_if_clean "test_narrow_exception_excludes_skill_agent_prompt_files"
}

echo "--- test_narrow_exception_excludes_skill_agent_prompt_files ---"
test_narrow_exception_excludes_skill_agent_prompt_files
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
