#!/usr/bin/env bash
# tests/skills/test-onboarding-confidence-assignment.sh
# Structural marker tests verifying that SKILL.md documents confidence level assignment
# rules for all 7 dimensions of the CONFIDENCE_CONTEXT signal (contract: confidence-context.md).
#
# Per Behavioral Testing Standard Rule 5, instruction files (SKILL.md) are tested at their
# structural boundary — grep checks on section headers and key content markers.
#
# Tests (RED — fail until SKILL.md documents confidence level assignment rules):
#   test_assignment_rules_section_present: SKILL.md contains a section describing confidence
#       level assignment (grep for 'confidence level' and 'assignment' or 'assign')
#   test_node_npm_high_confidence_example: SKILL.md documents that node-npm or a recognized
#       stack output maps to 'high' confidence
#   test_unknown_low_confidence_example: SKILL.md documents that 'unknown' stack output maps
#       to 'low' confidence
#   test_all_seven_dimensions_assigned: SKILL.md assigns confidence levels to all 7 dimensions
#       (stack, commands, architecture, infrastructure, ci, design, enforcement) in the
#       assignment rules block
#
# Story: 95ca-2d8e
# Task: 971f-5d18
# Contract: plugins/dso/docs/contracts/confidence-context.md
#
# Usage: bash tests/skills/test-onboarding-confidence-assignment.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-onboarding-confidence-assignment.sh ==="

# test_assignment_rules_section_present: SKILL.md must contain a section or subsection
# describing confidence level assignment — grep for 'confidence level' AND ('assignment' or 'assign')
test_assignment_rules_section_present() {
    _snapshot_fail
    local has_confidence_level="no"
    local has_assignment="no"
    if grep -qiE "confidence level" "$SKILL_MD" 2>/dev/null; then
        has_confidence_level="yes"
    fi
    if grep -qiE "\bassign(ment)?\b" "$SKILL_MD" 2>/dev/null; then
        has_assignment="yes"
    fi
    local result="missing"
    if [[ "$has_confidence_level" == "yes" && "$has_assignment" == "yes" ]]; then
        result="found"
    fi
    assert_eq "test_assignment_rules_section_present" "found" "$result"
    assert_pass_if_clean "test_assignment_rules_section_present"
}

# test_node_npm_high_confidence_example: SKILL.md must document that node-npm or a recognized
# stack output maps to 'high' confidence — grep for 'node-npm' (or recognized stack) near 'high'
test_node_npm_high_confidence_example() {
    _snapshot_fail
    local has_stack_high="no"
    # Check for 'node-npm' paired with 'high' anywhere in SKILL.md
    if grep -qiE "node.npm.*high|high.*node.npm" "$SKILL_MD" 2>/dev/null; then
        has_stack_high="yes"
    fi
    # Also accept any named-stack → high pattern (e.g., python-poetry, node-yarn, etc.)
    if [[ "$has_stack_high" == "no" ]] && \
       grep -qiE "(named stack|recognized stack|python.poetry|node.yarn|ruby.bundler).*high|high.*(named stack|recognized stack|python.poetry|node.yarn|ruby.bundler)" "$SKILL_MD" 2>/dev/null; then
        has_stack_high="yes"
    fi
    local result="missing"
    if [[ "$has_stack_high" == "yes" ]]; then
        result="found"
    fi
    assert_eq "test_node_npm_high_confidence_example" "found" "$result"
    assert_pass_if_clean "test_node_npm_high_confidence_example"
}

# test_unknown_low_confidence_example: SKILL.md must document that 'unknown' stack output
# maps to 'low' confidence — grep for 'unknown' near 'low' in the assignment context
test_unknown_low_confidence_example() {
    _snapshot_fail
    local has_unknown_low="no"
    if grep -qiE "unknown.*low|low.*unknown" "$SKILL_MD" 2>/dev/null; then
        has_unknown_low="yes"
    fi
    local result="missing"
    if [[ "$has_unknown_low" == "yes" ]]; then
        result="found"
    fi
    assert_eq "test_unknown_low_confidence_example" "found" "$result"
    assert_pass_if_clean "test_unknown_low_confidence_example"
}

# test_all_seven_dimensions_assigned: SKILL.md must assign confidence levels to all 7 dimensions
# (stack, commands, architecture, infrastructure, ci, design, enforcement) in the assignment
# rules block. Uses awk range to extract a Confidence Assignment or Confidence Level Assignment
# section; writes to a temp file to avoid echo-pipe-SIGPIPE issues with large files.
# Falls back to the full SKILL.md when no dedicated section header exists (expected RED state).
test_all_seven_dimensions_assigned() {
    _snapshot_fail
    local dims_found=0
    local dims_missing=""
    local required_dims=("stack" "commands" "architecture" "infrastructure" "ci" "design" "enforcement")
    local dim

    # Write the target search scope to a temp file to avoid echo-to-grep SIGPIPE with pipefail.
    local search_file
    search_file=$(mktemp)
    # Try to extract the confidence assignment block; fall back to full file if section absent.
    awk '/[Cc]onfidence [Aa]ssignment [Rr]ules?|[Cc]onfidence [Ll]evel [Aa]ssignment/,/^## /' \
        "$SKILL_MD" 2>/dev/null > "$search_file"
    if [[ ! -s "$search_file" ]]; then
        # Section not found — expected RED state. Use full file (all 7 dims present elsewhere
        # but the ASSIGNMENT RULES context is absent, so this test will still fail RED once
        # the assertion logic below checks for the dedicated section).
        cp "$SKILL_MD" "$search_file" 2>/dev/null || true
    fi

    # If the assignment section is absent (search_file came from the full file fallback),
    # this test must still fail RED. We enforce the RED state by checking that the
    # dedicated assignment section header exists first — if not, fail immediately.
    local has_assignment_section="no"
    if grep -qiE "[Cc]onfidence [Aa]ssignment [Rr]ules?|[Cc]onfidence [Ll]evel [Aa]ssignment" \
           "$SKILL_MD" 2>/dev/null; then
        has_assignment_section="yes"
    fi

    if [[ "$has_assignment_section" == "no" ]]; then
        rm -f "$search_file"
        assert_eq "test_all_seven_dimensions_assigned" \
            "7 dimensions assigned" \
            "0 dimensions found — Confidence Assignment Rules section absent from SKILL.md"
        assert_pass_if_clean "test_all_seven_dimensions_assigned"
        return
    fi

    for dim in "${required_dims[@]}"; do
        if grep -qiE "\b${dim}\b" "$search_file" 2>/dev/null; then
            (( dims_found++ )) || true
        else
            dims_missing="$dims_missing $dim"
        fi
    done
    rm -f "$search_file"

    if [[ "$dims_found" -eq 7 ]]; then
        assert_eq "test_all_seven_dimensions_assigned" "7 dimensions assigned" "7 dimensions assigned"
    else
        assert_eq "test_all_seven_dimensions_assigned" "7 dimensions assigned" "$dims_found dimensions found (missing:$dims_missing)"
    fi
    assert_pass_if_clean "test_all_seven_dimensions_assigned"
}

# Run all test functions
test_assignment_rules_section_present
test_node_npm_high_confidence_example
test_unknown_low_confidence_example
test_all_seven_dimensions_assigned

print_summary
