#!/usr/bin/env bash
# tests/skills/test-sprint-sc-coverage-haiku-gate.sh
# Structural RED tests for the SC coverage haiku gate sub-step in sprint SKILL.md.
#
# Validates that sprint SKILL.md contains the SC coverage haiku gate sub-step
# introduced by story d751-731a. All 5 assertions FAIL (RED) until the gate
# sub-step is added to SKILL.md by task 3b79-d74b.
#
# Bug/Story: d751-731a (SC coverage haiku gate)
#
# Tests:
#   test_sc_coverage_haiku_gate_heading
#     - SKILL.md must contain a sub-step labeled "SC Coverage Haiku Gate"
#   test_sc_coverage_haiku_gate_prompt_ref
#     - SKILL.md must reference the sc-coverage-haiku.md prompt file
#   test_sc_coverage_haiku_gate_fail_open
#     - SKILL.md must contain fail-open language for the gate
#   test_sc_coverage_haiku_gate_zero_sc_handling
#     - SKILL.md must contain handling for epics with 0 SCs
#   test_sc_coverage_haiku_gate_orchestrator_resume
#     - SKILL.md must contain ORCHESTRATOR_RESUME idempotency language
#       in the SC coverage / haiku gate context
#
# Rule 5 (behavioral testing standard): Test the structural boundary of the
# instruction file — SKILL.md is the executable specification consumed by the
# sprint orchestrator. The presence of the gate sub-step IS the behavioral
# artifact; without it, the orchestrator will not perform SC coverage checking.
#
# Usage:
#   bash tests/skills/test-sprint-sc-coverage-haiku-gate.sh

# [test_sc_coverage_haiku_gate]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-sc-coverage-haiku-gate.sh ==="

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_heading
# Sprint SKILL.md must contain a sub-step labeled "SC Coverage Haiku Gate"
# (or equivalent heading). The presence of this heading confirms the gate
# sub-step has been added to the orchestrator's instruction file.
#
# RED: heading does not exist until task 3b79-d74b adds it.
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_heading() {
    local match=0
    match=$(grep -cEi "SC Coverage Haiku Gate|SC coverage haiku gate" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_sc_coverage_haiku_gate_heading: SKILL.md contains SC Coverage Haiku Gate sub-step heading" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_prompt_ref
# The SC coverage haiku gate sub-step must reference the sc-coverage-haiku.md
# prompt file. This confirms the orchestrator is instructed to dispatch the
# haiku model with the correct prompt.
#
# RED: sc-coverage-haiku.md is not referenced until task 3b79-d74b adds it.
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_prompt_ref() {
    local match=0
    match=$(grep -ci "sc-coverage-haiku" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_sc_coverage_haiku_gate_prompt_ref: SKILL.md references sc-coverage-haiku.md prompt file" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_fail_open
# The SC coverage haiku gate sub-step must include fail-open language to ensure
# the sprint is not blocked when the haiku model fails or returns a parse error.
# Acceptable patterns: "fail-open", "parse failure", "parse.*fail".
#
# NOTE: While SKILL.md already contains some fail-open language in other
# contexts (e.g., ticket-clarity-check), this test checks for fail-open
# language specifically within the SC coverage haiku gate sub-step. The grep
# pattern below is intentionally narrow — it checks for "fail-open" OR
# "parse failure" near "SC coverage" or "haiku gate" context. Because the
# current SKILL.md has no SC coverage gate section at all, the context-aware
# check will fail RED.
#
# Implementation note: The test uses a two-pass approach:
#   Pass 1: extract the SC coverage haiku gate section (fails if section absent)
#   Pass 2: search for fail-open language within that section
#
# RED: section does not exist → extraction fails → pattern not found.
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_fail_open() {
    local match=0
    # Extract content near "SC Coverage Haiku Gate" and check for fail-open language.
    # grep -A 30 captures the sub-step body; if the heading is absent, no lines match.
    local section
    section=$(grep -A 30 -i "SC Coverage Haiku Gate\|SC coverage haiku gate" "$SKILL_FILE" 2>/dev/null) || section=""

    if [[ -n "$section" ]]; then
        match=$(echo "$section" | grep -cEi "fail-open|parse failure|parse.*fail") || match=0
        [[ "$match" -gt 0 ]] && match=1
    fi

    assert_eq "test_sc_coverage_haiku_gate_fail_open: SC coverage haiku gate sub-step contains fail-open language" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_zero_sc_handling
# The SC coverage haiku gate sub-step must explicitly handle the case where an
# epic has 0 SCs (no success criteria). This prevents the orchestrator from
# halting on epics that legitimately have no SCs yet.
# Acceptable patterns: "0-SC", "0 SC", "zero.*SC", "epics with 0".
#
# RED: section does not exist until task 3b79-d74b adds it.
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_zero_sc_handling() {
    local match=0
    # Extract content near "SC Coverage Haiku Gate" and check for 0-SC handling.
    local section
    section=$(grep -A 30 -i "SC Coverage Haiku Gate\|SC coverage haiku gate" "$SKILL_FILE" 2>/dev/null) || section=""

    if [[ -n "$section" ]]; then
        match=$(echo "$section" | grep -cEi "0-SC|0 SC|zero.*SC|epics with 0") || match=0
        [[ "$match" -gt 0 ]] && match=1
    fi

    assert_eq "test_sc_coverage_haiku_gate_zero_sc_handling: SC coverage haiku gate sub-step contains 0-SC epic handling" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_orchestrator_resume
# The SC coverage haiku gate sub-step must contain ORCHESTRATOR_RESUME
# idempotency language so that a resumed sprint does not re-run the gate
# unnecessarily. This check looks for ORCHESTRATOR_RESUME within 50 lines of
# the gate heading.
#
# RED: section does not exist until task 3b79-d74b adds it.
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_orchestrator_resume() {
    local match=0
    # Extract content near "SC Coverage Haiku Gate" and check for ORCHESTRATOR_RESUME.
    local section
    section=$(grep -A 50 -i "SC Coverage Haiku Gate\|SC coverage haiku gate" "$SKILL_FILE" 2>/dev/null) || section=""

    if [[ -n "$section" ]]; then
        match=$(echo "$section" | grep -c "ORCHESTRATOR_RESUME") || match=0
        [[ "$match" -gt 0 ]] && match=1
    fi

    assert_eq "test_sc_coverage_haiku_gate_orchestrator_resume: SC coverage haiku gate sub-step contains ORCHESTRATOR_RESUME idempotency language" "1" "$match"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_heading
test_sc_coverage_haiku_gate_prompt_ref
test_sc_coverage_haiku_gate_fail_open
test_sc_coverage_haiku_gate_zero_sc_handling
test_sc_coverage_haiku_gate_orchestrator_resume

print_summary

# ---------------------------------------------------------------------------
# Test-gate anchor block — literal test names for record-test-status.sh
# ---------------------------------------------------------------------------
_TEST_GATE_ANCHORS=(
    test_sc_coverage_haiku_gate_heading
    test_sc_coverage_haiku_gate_prompt_ref
    test_sc_coverage_haiku_gate_fail_open
    test_sc_coverage_haiku_gate_zero_sc_handling
    test_sc_coverage_haiku_gate_orchestrator_resume
)
