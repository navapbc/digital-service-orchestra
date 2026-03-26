#!/usr/bin/env bash
# tests/scripts/test-explore-dispatch-template.sh
# TDD tests for the explore agent structured output prompt template.
# Template path: plugins/dso/scripts/agent-profiles/prompts/explore-structured-output.md
#
# Tests:
#  1. test_template_file_exists          — template exists at expected path
#  2. test_template_requires_numbered_list — contains numbered/enumerated list output requirement
#  3. test_template_requires_categorization — contains per-file categorization (primary/secondary/tangential)
#  4. test_template_requires_completeness_check — contains completeness self-check section
#  5. test_template_requires_term_matching — contains instruction to match ALL terms from request
#  6. test_template_is_tech_stack_agnostic — does NOT contain DSO-specific paths (negative constraint)
#  7. test_template_has_request_placeholder — contains {exploration_request} placeholder
#  8. test_template_has_output_example   — contains structured output format example
#
# Usage: bash tests/scripts/test-explore-dispatch-template.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED STATE: These tests currently FAIL because the template file does not exist yet.
# They will pass (GREEN) after explore-structured-output.md is created.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE_PATH="$PLUGIN_ROOT/plugins/dso/scripts/agent-profiles/prompts/explore-structured-output.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-explore-dispatch-template.sh ==="

# ── test_template_file_exists ─────────────────────────────────────────────────
# The template must exist at plugins/dso/scripts/agent-profiles/prompts/explore-structured-output.md
test_template_file_exists() {
    _snapshot_fail
    local _actual
    if [[ -f "$TEMPLATE_PATH" ]]; then
        _actual="exists"
    else
        _actual="missing"
    fi
    assert_eq "test_template_file_exists: template at expected path" "exists" "$_actual"
    assert_pass_if_clean "test_template_file_exists"
}

# ── test_template_requires_numbered_list ──────────────────────────────────────
# Template must instruct the agent to produce a numbered/enumerated list output.
test_template_requires_numbered_list() {
    _snapshot_fail
    local _content _found=0
    if [[ -f "$TEMPLATE_PATH" ]]; then
        _content=$(cat "$TEMPLATE_PATH")
        if echo "$_content" | grep -qiE '(numbered list|enumerat|[0-9]+\.)'; then
            _found=1
        fi
    fi
    assert_eq "test_template_requires_numbered_list: contains numbered/enumerated list requirement" "1" "$_found"
    assert_pass_if_clean "test_template_requires_numbered_list"
}

# ── test_template_requires_categorization ────────────────────────────────────
# Template must contain per-file categorization instruction with
# primary / secondary / tangential relevance tiers.
test_template_requires_categorization() {
    _snapshot_fail
    local _content _found=0
    if [[ -f "$TEMPLATE_PATH" ]]; then
        _content=$(cat "$TEMPLATE_PATH")
        if echo "$_content" | grep -qiE '(primary|secondary|tangential)'; then
            _found=1
        fi
    fi
    assert_eq "test_template_requires_categorization: contains primary/secondary/tangential categorization" "1" "$_found"
    assert_pass_if_clean "test_template_requires_categorization"
}

# ── test_template_requires_completeness_check ────────────────────────────────
# Template must include a completeness self-check section instructing the agent
# to verify its own output before returning.
test_template_requires_completeness_check() {
    _snapshot_fail
    local _content _found=0
    if [[ -f "$TEMPLATE_PATH" ]]; then
        _content=$(cat "$TEMPLATE_PATH")
        if echo "$_content" | grep -qiE '(completeness|self.check|verify.*output|check.*complete)'; then
            _found=1
        fi
    fi
    assert_eq "test_template_requires_completeness_check: contains completeness self-check section" "1" "$_found"
    assert_pass_if_clean "test_template_requires_completeness_check"
}

# ── test_template_requires_term_matching ─────────────────────────────────────
# Template must instruct the agent to match ALL terms from the exploration request.
test_template_requires_term_matching() {
    _snapshot_fail
    local _content _found=0
    if [[ -f "$TEMPLATE_PATH" ]]; then
        _content=$(cat "$TEMPLATE_PATH")
        if echo "$_content" | grep -qiE '(all terms|every term|match.*term|term.*match)'; then
            _found=1
        fi
    fi
    assert_eq "test_template_requires_term_matching: contains instruction to match ALL terms from request" "1" "$_found"
    assert_pass_if_clean "test_template_requires_term_matching"
}

# ── test_template_is_tech_stack_agnostic ─────────────────────────────────────
# Template must NOT contain DSO-specific paths that would make it repo-specific.
# Negative constraint: .tickets/, plugins/dso/, app/src/ must NOT appear.
test_template_is_tech_stack_agnostic() {
    _snapshot_fail
    local _content _found=0
    if [[ -f "$TEMPLATE_PATH" ]]; then
        _content=$(cat "$TEMPLATE_PATH")
        if echo "$_content" | grep -qE '(\.tickets/|plugins/dso/|app/src/)'; then
            _found=1
        fi
    fi
    assert_eq "test_template_is_tech_stack_agnostic: does NOT contain DSO-specific paths" "0" "$_found"
    assert_pass_if_clean "test_template_is_tech_stack_agnostic"
}

# ── test_template_has_request_placeholder ────────────────────────────────────
# Template must contain the {exploration_request} placeholder so the caller
# can inject the actual exploration query at runtime.
test_template_has_request_placeholder() {
    _snapshot_fail
    local _content _found=0
    if [[ -f "$TEMPLATE_PATH" ]]; then
        _content=$(cat "$TEMPLATE_PATH")
        if echo "$_content" | grep -qF '{exploration_request}'; then
            _found=1
        fi
    fi
    assert_eq "test_template_has_request_placeholder: contains {exploration_request} placeholder" "1" "$_found"
    assert_pass_if_clean "test_template_has_request_placeholder"
}

# ── test_template_has_output_example ─────────────────────────────────────────
# Template must contain a structured output format example so the agent
# knows the expected shape of its response.
test_template_has_output_example() {
    _snapshot_fail
    local _content _found=0
    if [[ -f "$TEMPLATE_PATH" ]]; then
        _content=$(cat "$TEMPLATE_PATH")
        if echo "$_content" | grep -qiE '(example|output format|format.*example|e\.g\.|e\.g:)'; then
            _found=1
        fi
    fi
    assert_eq "test_template_has_output_example: contains structured output format example" "1" "$_found"
    assert_pass_if_clean "test_template_has_output_example"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_template_file_exists
test_template_requires_numbered_list
test_template_requires_categorization
test_template_requires_completeness_check
test_template_requires_term_matching
test_template_is_tech_stack_agnostic
test_template_has_request_placeholder
test_template_has_output_example

print_summary
