#!/usr/bin/env bash
# tests/agents/test-red-test-evaluator.sh
# Verifies the red-test-evaluator agent definition (plugins/dso/agents/red-test-evaluator.md)
# contains the expected frontmatter, verdict sections, output contract, and decision logic.
#
# Usage: bash tests/agents/test-red-test-evaluator.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: This test does NOT guard-exit when the agent file is absent.
# Each test fails explicitly when the file is missing (RED phase behavior).
#
# Tests use structural grep patterns — accepted exception for agent definition files
# (no runtime behavior). This matches the precedent set by test-red-test-writer.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/red-test-evaluator.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-red-test-evaluator.sh ==="
echo ""

# ============================================================
# test_frontmatter_has_name_red_test_evaluator
# YAML frontmatter must declare name: red-test-evaluator
# ============================================================
test_frontmatter_has_name_red_test_evaluator() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_frontmatter_has_name_red_test_evaluator"
        return
    fi
    local _found=0
    if grep -q 'name:.*red-test-evaluator' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "frontmatter has name: red-test-evaluator" "1" "$_found"
    assert_pass_if_clean "test_frontmatter_has_name_red_test_evaluator"
}

# ============================================================
# test_frontmatter_has_model_opus
# YAML frontmatter must declare model: opus (or claude-opus variant)
# ============================================================
test_frontmatter_has_model_opus() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_frontmatter_has_model_opus"
        return
    fi
    local _found=0
    if grep -qi 'model:.*opus' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "frontmatter has model: opus" "1" "$_found"
    assert_pass_if_clean "test_frontmatter_has_model_opus"
}

# ============================================================
# test_has_revise_verdict_section
# Agent must include a REVISE verdict section
# ============================================================
test_has_revise_verdict_section() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_has_revise_verdict_section"
        return
    fi
    local _found=0
    if grep -qi 'REVISE' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "agent has REVISE verdict section" "1" "$_found"
    assert_pass_if_clean "test_has_revise_verdict_section"
}

# ============================================================
# test_has_reject_verdict_section
# Agent must include a REJECT verdict section
# ============================================================
test_has_reject_verdict_section() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_has_reject_verdict_section"
        return
    fi
    local _found=0
    if grep -qi 'REJECT' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "agent has REJECT verdict section" "1" "$_found"
    assert_pass_if_clean "test_has_reject_verdict_section"
}

# ============================================================
# test_has_confirm_verdict_section
# Agent must include a CONFIRM verdict section
# ============================================================
test_has_confirm_verdict_section() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_has_confirm_verdict_section"
        return
    fi
    local _found=0
    if grep -qi 'CONFIRM' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "agent has CONFIRM verdict section" "1" "$_found"
    assert_pass_if_clean "test_has_confirm_verdict_section"
}

# ============================================================
# test_revise_includes_impact_assessment
# REVISE section must reference impact_assessment
# ============================================================
test_revise_includes_impact_assessment() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_revise_includes_impact_assessment"
        return
    fi
    local _found=0
    if grep -qi 'impact_assessment\|impact assessment' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "REVISE section includes impact_assessment" "1" "$_found"
    assert_pass_if_clean "test_revise_includes_impact_assessment"
}

# ============================================================
# test_revise_mentions_in_progress_and_closed
# REVISE section must mention both in-progress and closed task states
# ============================================================
test_revise_mentions_in_progress_and_closed() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_revise_mentions_in_progress_and_closed"
        return
    fi
    local _found_in_progress=0
    local _found_closed=0
    if grep -qi 'in.progress\|in_progress' "$AGENT_FILE" 2>/dev/null; then
        _found_in_progress=1
    fi
    if grep -qi '\bclosed\b' "$AGENT_FILE" 2>/dev/null; then
        _found_closed=1
    fi
    assert_eq "REVISE section mentions in-progress state" "1" "$_found_in_progress"
    assert_eq "REVISE section mentions closed state" "1" "$_found_closed"
    assert_pass_if_clean "test_revise_mentions_in_progress_and_closed"
}

# ============================================================
# test_confirm_infeasibility_categories
# CONFIRM section must list all 4 infeasibility categories:
# infrastructure, injection, documentation, reference_removal
# ============================================================
test_confirm_infeasibility_categories() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_confirm_infeasibility_categories"
        return
    fi
    local _found_infrastructure=0
    local _found_injection=0
    local _found_documentation=0
    local _found_reference_removal=0
    if grep -qi 'infrastructure' "$AGENT_FILE" 2>/dev/null; then _found_infrastructure=1; fi
    if grep -qi 'injection' "$AGENT_FILE" 2>/dev/null; then _found_injection=1; fi
    if grep -qi 'documentation' "$AGENT_FILE" 2>/dev/null; then _found_documentation=1; fi
    if grep -qi 'reference_removal\|reference removal' "$AGENT_FILE" 2>/dev/null; then _found_reference_removal=1; fi
    assert_eq "CONFIRM section includes infrastructure category" "1" "$_found_infrastructure"
    assert_eq "CONFIRM section includes injection category" "1" "$_found_injection"
    assert_eq "CONFIRM section includes documentation category" "1" "$_found_documentation"
    assert_eq "CONFIRM section includes reference_removal category" "1" "$_found_reference_removal"
    assert_pass_if_clean "test_confirm_infeasibility_categories"
}

# ============================================================
# test_input_contract_references_writer_output
# Agent must reference red-test-writer output as its input
# ============================================================
test_input_contract_references_writer_output() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_input_contract_references_writer_output"
        return
    fi
    local _found=0
    if grep -qi 'red-test-writer\|red_test_writer' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "input contract references red-test-writer output" "1" "$_found"
    assert_pass_if_clean "test_input_contract_references_writer_output"
}

# ============================================================
# test_output_contract_specifies_json_format
# Output contract must specify JSON format (not YAML or prose)
# ============================================================
test_output_contract_specifies_json_format() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_output_contract_specifies_json_format"
        return
    fi
    local _found=0
    if grep -qi 'json' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "output contract specifies JSON format" "1" "$_found"
    assert_pass_if_clean "test_output_contract_specifies_json_format"
}

# ============================================================
# test_output_contract_has_verdict_field
# Output contract must define a verdict field
# ============================================================
test_output_contract_has_verdict_field() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_output_contract_has_verdict_field"
        return
    fi
    local _found=0
    if grep -qi '"verdict"\|verdict:' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "output contract has verdict field" "1" "$_found"
    assert_pass_if_clean "test_output_contract_has_verdict_field"
}

# ============================================================
# test_has_decision_logic_section
# Agent must include a decision logic or routing logic section
# ============================================================
test_has_decision_logic_section() {
    _snapshot_fail
    if [[ ! -f "$AGENT_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: agent file not found: %s\n" "$AGENT_FILE" >&2
        assert_pass_if_clean "test_has_decision_logic_section"
        return
    fi
    local _found=0
    if grep -qi 'Decision Logic\|Routing Logic\|decision_logic\|routing_logic' "$AGENT_FILE" 2>/dev/null; then
        _found=1
    fi
    assert_eq "agent has Decision Logic section" "1" "$_found"
    assert_pass_if_clean "test_has_decision_logic_section"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "--- test_frontmatter_has_name_red_test_evaluator ---"
test_frontmatter_has_name_red_test_evaluator
echo ""

echo "--- test_frontmatter_has_model_opus ---"
test_frontmatter_has_model_opus
echo ""

echo "--- test_has_revise_verdict_section ---"
test_has_revise_verdict_section
echo ""

echo "--- test_has_reject_verdict_section ---"
test_has_reject_verdict_section
echo ""

echo "--- test_has_confirm_verdict_section ---"
test_has_confirm_verdict_section
echo ""

echo "--- test_revise_includes_impact_assessment ---"
test_revise_includes_impact_assessment
echo ""

echo "--- test_revise_mentions_in_progress_and_closed ---"
test_revise_mentions_in_progress_and_closed
echo ""

echo "--- test_confirm_infeasibility_categories ---"
test_confirm_infeasibility_categories
echo ""

echo "--- test_input_contract_references_writer_output ---"
test_input_contract_references_writer_output
echo ""

echo "--- test_output_contract_specifies_json_format ---"
test_output_contract_specifies_json_format
echo ""

echo "--- test_output_contract_has_verdict_field ---"
test_output_contract_has_verdict_field
echo ""

echo "--- test_has_decision_logic_section ---"
test_has_decision_logic_section
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
