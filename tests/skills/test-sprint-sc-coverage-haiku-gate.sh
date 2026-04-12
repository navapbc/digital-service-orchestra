#!/usr/bin/env bash
# tests/skills/test-sprint-sc-coverage-haiku-gate.sh
# Structural boundary tests for the SC Coverage Haiku Gate sub-step in
# sprint SKILL.md's Preplanning Gate.
#
# Verifies that the SC Coverage Haiku Gate sub-step exists after the
# Existing Children Readiness Check (Step 2a) with all required language:
# the sub-step heading, prompt file reference, fail-open language,
# 0-SC handling, and ORCHESTRATOR_RESUME idempotency.
#
# Bugs: 3b79-d74b
#
# Tests:
#   test_sc_coverage_haiku_gate_heading
#     - SKILL.md must contain a sub-step heading for the SC Coverage Haiku Gate
#   test_sc_coverage_haiku_gate_prompt_ref
#     - SKILL.md must reference sc-coverage-haiku.md prompt file in the sub-step
#   test_sc_coverage_haiku_gate_fail_open
#     - SKILL.md must contain fail-open language (parse failure → skip + warn)
#   test_sc_coverage_haiku_gate_zero_sc_handling
#     - SKILL.md must contain 0-SC epic handling language
#   test_sc_coverage_haiku_gate_orchestrator_resume
#     - SKILL.md must contain ORCHESTRATOR_RESUME idempotency for the gate
#
# RED phase: all tests fail until SC Coverage Haiku Gate sub-step is added.
# GREEN phase: pass after sub-step is added to sprint SKILL.md.
#
# Usage:
#   bash tests/skills/test-sprint-sc-coverage-haiku-gate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-sc-coverage-haiku-gate.sh ==="

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_heading
# The Preplanning Gate section must contain a sub-step heading that clearly
# labels the SC Coverage Haiku Gate (case-insensitive match).
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_heading() {
    local match=0
    match=$(grep -ciE "sc coverage haiku gate|sc_coverage.*haiku|haiku.*sc.*coverage|sc.*coverage.*haiku gate" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_sc_coverage_haiku_gate_heading: SC Coverage Haiku Gate heading present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_prompt_ref
# The SC Coverage Haiku Gate sub-step must reference the prompt file
# plugins/dso/skills/sprint/prompts/sc-coverage-haiku.md so the orchestrator
# knows which prompt schema to use when dispatching the haiku sub-agent.
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_prompt_ref() {
    local match=0
    match=$(grep -c "sc-coverage-haiku.md" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_sc_coverage_haiku_gate_prompt_ref: sc-coverage-haiku.md prompt reference present" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_fail_open
# The SC Coverage Haiku Gate must be fail-open: when JSON parsing fails
# (malformed output, timeout, etc.) the gate logs a warning, skips the check,
# and proceeds rather than blocking execution.
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_fail_open() {
    local match=0
    match=$(grep -ciE "fail-open|parse failure|parse.*fail[^s]|fail.*open|malformed.*json|json.*malformed|parse.*error.*skip|skip.*parse.*error" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_sc_coverage_haiku_gate_fail_open: fail-open parse-failure language present" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_zero_sc_handling
# The SC Coverage Haiku Gate must handle epics with 0 success criteria
# trivially: log a warning and skip the gate without dispatching the haiku
# sub-agent.
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_zero_sc_handling() {
    local match=0
    match=$(grep -ciE "0-SC|0 SC|zero.*SC[^a-z]|SC.*0[^-9]|empty.*SC|no SC[^a-z]|SCs.*empty|epics with 0|0.*success criteria" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_sc_coverage_haiku_gate_zero_sc_handling: 0-SC epic handling language present" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_sc_coverage_haiku_gate_orchestrator_resume
# The SC Coverage Haiku Gate must include an ORCHESTRATOR_RESUME idempotency
# block so that resume context can skip the gate if it already completed.
# The ORCHESTRATOR_RESUME keyword must appear within 50 lines of the gate
# heading in the file.
# ---------------------------------------------------------------------------
test_sc_coverage_haiku_gate_orchestrator_resume() {
    local match=0
    # Find the line number of the gate heading
    local gate_line
    gate_line=$(grep -niE "sc coverage haiku gate|sc_coverage.*haiku|haiku.*sc.*coverage" "$SKILL_FILE" 2>/dev/null | head -1 | cut -d: -f1)
    if [[ -z "$gate_line" ]]; then
        match=0
    else
        local start_line=$(( gate_line > 1 ? gate_line : 1 ))
        local end_line=$(( gate_line + 50 ))
        match=$(awk "NR>=$start_line && NR<=$end_line" "$SKILL_FILE" | grep -c "ORCHESTRATOR_RESUME") || match=0
        [[ "$match" -gt 0 ]] && match=1
    fi
    assert_eq "test_sc_coverage_haiku_gate_orchestrator_resume: ORCHESTRATOR_RESUME idempotency block present within 50 lines of gate heading" "1" "$match"
}

# ---------------------------------------------------------------------------
# Run tests
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
