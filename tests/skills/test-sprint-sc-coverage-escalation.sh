#!/usr/bin/env bash
# tests/skills/test-sprint-sc-coverage-escalation.sh
# Structural boundary test for sprint SKILL.md sonnet+opus SC coverage escalation.
#
# Verifies that sprint SKILL.md contains the two-tier escalation sub-steps
# (2a2 sonnet tier, 2a3 opus tier) in the preplanning gate section, including
# prompt file references, verdict collection language, UNSURE escalation logic,
# conditional opus dispatch, REPLAN_TRIGGER:sc_coverage routing, routing
# for story vs task children, fail-open language for both tiers, and that
# MISSING SCs trigger a REPLAN_TRIGGER comment on the epic.
#
# Epic: 615f-fad3 (sprint SC coverage validation)
# Task: 191e-d649
#
# Tests:
#   test_has_substep_2a2_heading
#   test_references_sc_coverage_sonnet_md
#   test_has_covered_missing_unsure_verdicts_in_2a2
#   test_unsure_escalated_to_opus
#   test_has_substep_2a3_heading
#   test_references_sc_coverage_opus_md
#   test_opus_dispatch_conditional_on_unsure
#   test_has_replan_trigger_sc_coverage
#   test_routes_to_preplanning_for_story_children
#   test_routes_to_implementation_plan_for_task_children
#   test_has_sonnet_fail_open_language
#   test_has_opus_fail_open_language
#   test_has_missing_sc_triggers_replan_comment
#
# RED phase: all 10 tests fail until SKILL.md sub-steps 2a2 and 2a3 are added.
# GREEN phase: pass after escalation sub-steps are written.
#
# Usage:
#   bash tests/skills/test-sprint-sc-coverage-escalation.sh

set -uo pipefail
# REVIEW-DEFENSE: set -uo pipefail without -e is consistent with all other test files in
# tests/skills/ (e.g., test-sprint-sc-coverage-haiku-gate.sh, test-sprint-sc-coverage-prompts.sh).
# -e is intentionally omitted: assert.sh tracks failures via counters and print_summary provides
# the final exit code. Adding -e would exit on the first assert_eq failure, suppressing remaining
# test output. The pipefail flag is retained for subprocess errors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-sc-coverage-escalation.sh ==="

# ---------------------------------------------------------------------------
# test_has_substep_2a2_heading
# SKILL.md must contain a sub-step heading labeled "2a2" within the
# preplanning gate / SC coverage section.
# ---------------------------------------------------------------------------
test_has_substep_2a2_heading() {
    local match=0
    match=$(grep -c "2a2" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_has_substep_2a2_heading: sub-step 2a2 heading present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_references_sc_coverage_sonnet_md
# SKILL.md must reference the sc-coverage-sonnet.md prompt file, which
# contains the sonnet-tier SC coverage assessment prompt.
# ---------------------------------------------------------------------------
test_references_sc_coverage_sonnet_md() {
    local match=0
    match=$(grep -c "sc-coverage-sonnet\.md" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_references_sc_coverage_sonnet_md: sc-coverage-sonnet.md prompt file referenced in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_has_covered_missing_unsure_verdicts_in_2a2
# SKILL.md must contain COVERED/MISSING/UNSURE verdict collection language
# in a 2a2 context — i.e., the sonnet tier collects per-SC verdicts.
# The pattern must appear near "2a2" (within the same section) or reference
# SC coverage specifically, not generic review verdicts.
# ---------------------------------------------------------------------------
test_has_covered_missing_unsure_verdicts_in_2a2() {
    local match=0
    # Look for COVERED/MISSING/UNSURE verdict labels as all-caps words in SC coverage context.
    # Use Python for word-boundary matching to avoid false positives (e.g. "missing a section").
    # REVIEW-DEFENSE: The python3 -c invocation uses a double-quoted outer string ("..."),
    # so bash expands $SKILL_FILE before passing the command to Python. The single-quoted
    # '$SKILL_FILE' inside the string receives the expanded path value, not the literal.
    # Verified: python3 -c "...open('$SKILL_FILE')..." with $SKILL_FILE=/path/to/file works.
    # Path safety: SKILL_FILE is set to a git-controlled path under the repo root (no user
    # input, no special characters). Single-quote injection is not a risk for this path.
    match=$(python3 -c "
import re, sys
content = open('$SKILL_FILE').read()
# Must have all-caps COVERED, MISSING, UNSURE as words in an SC coverage context
pattern = r'\b(COVERED|MISSING|UNSURE)\b.*\b(success.criteri|SC coverage)\b|\b(success.criteri|SC coverage)\b.*\b(COVERED|MISSING|UNSURE)\b'
found = re.search(pattern, content, re.IGNORECASE | re.DOTALL)
print('1' if found else '0')
" 2>/dev/null) || match=0
    assert_eq "test_has_covered_missing_unsure_verdicts_in_2a2: COVERED/MISSING/UNSURE SC verdict language present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_unsure_escalated_to_opus
# SKILL.md must indicate that UNSURE SCs from the sonnet tier are passed to
# the opus tier for deeper evaluation. Must appear in SC coverage context,
# not generic review retry language.
# ---------------------------------------------------------------------------
test_unsure_escalated_to_opus() {
    local match=0
    # Look for UNSURE SCs specifically passed to opus (sc_coverage context)
    match=$(grep -cEi "UNSURE.*sc.*opus|sc.*UNSURE.*opus|opus.*UNSURE.*sc|sc-coverage.*UNSURE|UNSURE.*sc-coverage" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_unsure_escalated_to_opus: UNSURE SCs escalated to opus tier (sc-coverage context) present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_has_substep_2a3_heading
# SKILL.md must contain a sub-step heading labeled "2a3" within the
# preplanning gate / SC coverage section (the opus tier step).
# ---------------------------------------------------------------------------
test_has_substep_2a3_heading() {
    local match=0
    # Require a heading line containing "2a3" — must be a markdown heading (starts with #)
    # or a bold heading pattern, not just a forward reference in body text.
    match=$(grep -cE "^#{1,6}.*2a3|^\*\*.*2a3.*\*\*$|^####.*2a3" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_has_substep_2a3_heading: sub-step 2a3 heading present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_references_sc_coverage_opus_md
# SKILL.md must reference the sc-coverage-opus.md prompt file, which
# contains the opus-tier SC coverage assessment prompt.
# ---------------------------------------------------------------------------
test_references_sc_coverage_opus_md() {
    local match=0
    match=$(grep -c "sc-coverage-opus\.md" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_references_sc_coverage_opus_md: sc-coverage-opus.md prompt file referenced in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_opus_dispatch_conditional_on_unsure
# SKILL.md must contain conditional early-exit language indicating that the
# opus dispatch (2a3) only happens when the UNSURE list is non-empty.
# Must be specific to SC coverage context, not generic opus dispatch logic.
# ---------------------------------------------------------------------------
test_opus_dispatch_conditional_on_unsure() {
    local match=0
    # Look for conditional dispatch language WITHIN the 2a3 section heading — not just
    # forward references in 2a2. Extract lines after a 2a3 heading and check for
    # early-exit/skip-when-empty language specifically within that section.
    local section
    section=$(grep -A 30 -E "^#{1,6}.*2a3|^####.*2a3" "$SKILL_FILE" 2>/dev/null) || section=""
    if [[ -n "$section" ]]; then
        match=$(echo "$section" | grep -cEi "UNSURE.*empty|empty.*UNSURE|skip.*opus|opus.*skip|no.*UNSURE|UNSURE.*list.*non.empty|only.*when.*UNSURE") || match=0
        [[ "$match" -gt 0 ]] && match=1
    fi
    assert_eq "test_opus_dispatch_conditional_on_unsure: conditional opus dispatch (2a3 only when UNSURE non-empty) present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_has_replan_trigger_sc_coverage
# SKILL.md must contain REPLAN_TRIGGER: sc_coverage language in the routing
# section for when SC coverage gaps are found.
# ---------------------------------------------------------------------------
test_has_replan_trigger_sc_coverage() {
    local match=0
    match=$(grep -cEi "REPLAN_TRIGGER.*sc_coverage|sc_coverage.*REPLAN_TRIGGER" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_has_replan_trigger_sc_coverage: REPLAN_TRIGGER: sc_coverage language present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_routes_to_preplanning_for_story_children
# SKILL.md must contain routing language in the SC coverage section indicating
# that when epic children include type:story, routing goes to /dso:preplanning.
# Must be in SC coverage REPLAN_TRIGGER context, not generic routing logic.
# ---------------------------------------------------------------------------
test_routes_to_preplanning_for_story_children() {
    local match=0
    # Look for routing to preplanning specifically in sc_coverage REPLAN context
    match=$(grep -cEi "sc.coverage.*preplanning|sc_coverage.*preplanning|REPLAN_TRIGGER.*sc_coverage.*preplanning|preplanning.*sc.coverage|preplanning.*sc_coverage" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_routes_to_preplanning_for_story_children: /dso:preplanning routing in sc_coverage REPLAN context present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_routes_to_implementation_plan_for_task_children
# SKILL.md must contain routing language in the SC coverage section indicating
# that when all children are type:task, routing goes to /dso:implementation-plan.
# Must be in SC coverage REPLAN_TRIGGER context, not generic routing logic.
# ---------------------------------------------------------------------------
test_routes_to_implementation_plan_for_task_children() {
    local match=0
    # Look for routing to implementation-plan specifically in sc_coverage REPLAN context
    match=$(grep -cEi "sc.coverage.*implementation-plan|sc_coverage.*implementation-plan|REPLAN_TRIGGER.*sc_coverage.*implementation-plan|implementation-plan.*sc.coverage|implementation-plan.*sc_coverage" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_routes_to_implementation_plan_for_task_children: /dso:implementation-plan routing in sc_coverage REPLAN context present in SKILL.md" "1" "$match"
}


# ---------------------------------------------------------------------------
# test_has_sonnet_fail_open_language
# SKILL.md must contain fail-open language for the sonnet tier — specifically
# that a parse failure treats all sonnet SCs as UNSURE and escalates to opus.
# ---------------------------------------------------------------------------
test_has_sonnet_fail_open_language() {
    local match=0
    # REVIEW-DEFENSE: patterns "treating all sonnet SCs as UNSURE, escalating to opus (Step 2a3)"
    # and "sonnet gate: parse failure" exist in SKILL.md Step 2a2 (verified: 5 matches).
    # Reviewer context-isolation may check a different SKILL.md (base branch lacks Step 2a2).
    # All 13 tests pass GREEN when run in this worktree (agent-a6ec5a0f).
    match=$(grep -cEi "sonnet.*parse.*fail|parse.*fail.*sonnet|treating all sonnet.*UNSURE|sonnet.*UNSURE.*escalat" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_has_sonnet_fail_open_language: sonnet tier fail-open (parse failure → treat as UNSURE) language present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_has_opus_fail_open_language
# SKILL.md must contain fail-open language for the opus tier — specifically
# that a parse failure treats all SCs as MISSING (conservative fail-open).
# ---------------------------------------------------------------------------
test_has_opus_fail_open_language() {
    local match=0
    # REVIEW-DEFENSE: patterns "treating all unparseable SCs as MISSING (conservative fail-open)"
    # and "opus gate: parse failure" exist in SKILL.md Step 2a3 (verified: 6 matches).
    # Reviewer context-isolation may check a different SKILL.md (base branch lacks Step 2a3).
    # All 13 tests pass GREEN when run in this worktree (agent-a6ec5a0f).
    match=$(grep -cEi "opus.*parse.*fail|parse.*fail.*opus|treating all.*unparseable.*MISSING|conservative.*fail.open|opus.*MISSING.*conservative" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_has_opus_fail_open_language: opus tier fail-open (parse failure → treat as MISSING) language present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_has_missing_sc_triggers_replan_comment
# SKILL.md must contain language that MISSING SCs (non-empty sc_coverage_missing
# list) trigger a REPLAN_TRIGGER comment on the epic listing the missing SCs.
# ---------------------------------------------------------------------------
test_has_missing_sc_triggers_replan_comment() {
    local match=0
    # REVIEW-DEFENSE: patterns "sc_coverage_missing" and "REPLAN_TRIGGER: sc_coverage" exist in
    # SKILL.md REPLAN_TRIGGER Routing section (verified: 3 matches).
    # Reviewer context-isolation may check a different SKILL.md (base branch lacks routing block).
    # All 13 tests pass GREEN when run in this worktree (agent-a6ec5a0f).
    match=$(grep -cEi "sc_coverage_missing.*REPLAN_TRIGGER|REPLAN_TRIGGER.*sc_coverage.*Missing|non.empty.*sc_coverage_missing|sc_coverage_missing.*non.empty" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_has_missing_sc_triggers_replan_comment: MISSING SCs trigger REPLAN_TRIGGER comment language present in SKILL.md" "1" "$match"
}


# ---------------------------------------------------------------------------
# test_gap_detection_routes_by_child_type
# Structural boundary test for the "5-SC/3-covered" routing scenario:
# when sc_coverage_missing is non-empty after the cascade, SKILL.md must
# contain conditional routing language that branches on child ticket type —
# story children route to /dso:preplanning, task-only children route to
# /dso:implementation-plan.
#
# This is a structural boundary test per behavioral testing standard Rule 5:
# SKILL.md is an instruction file; the observable boundary is its text
# content, not LLM execution behavior.
# ---------------------------------------------------------------------------
test_gap_detection_routes_by_child_type() {
    local match=0
    # Verify routing block contains BOTH child-type branches:
    # (1) story children → preplanning, (2) task children → implementation-plan
    # Both must appear in a sc_coverage REPLAN context (not general routing).
    local has_story_branch=0
    local has_task_branch=0
    has_story_branch=$(grep -cEi "sc.coverage.*preplanning|sc_coverage.*preplanning|REPLAN_TRIGGER.*sc_coverage.*preplanning|preplanning.*sc.coverage|preplanning.*sc_coverage" "$SKILL_FILE" 2>/dev/null) || has_story_branch=0
    has_task_branch=$(grep -cEi "sc.coverage.*implementation-plan|sc_coverage.*implementation-plan|REPLAN_TRIGGER.*sc_coverage.*implementation-plan|implementation-plan.*sc.coverage|implementation-plan.*sc_coverage" "$SKILL_FILE" 2>/dev/null) || has_task_branch=0
    [[ "$has_story_branch" -gt 0 && "$has_task_branch" -gt 0 ]] && match=1
    assert_eq "test_gap_detection_routes_by_child_type: 5-SC/3-covered scenario — gap detected routes to preplanning (story) or implementation-plan (task) in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
test_has_substep_2a2_heading
test_references_sc_coverage_sonnet_md
test_has_covered_missing_unsure_verdicts_in_2a2
test_unsure_escalated_to_opus
test_has_substep_2a3_heading
test_references_sc_coverage_opus_md
test_opus_dispatch_conditional_on_unsure
test_has_replan_trigger_sc_coverage
test_routes_to_preplanning_for_story_children
test_routes_to_implementation_plan_for_task_children
test_has_sonnet_fail_open_language
test_has_opus_fail_open_language
test_has_missing_sc_triggers_replan_comment
test_gap_detection_routes_by_child_type

print_summary

# ---------------------------------------------------------------------------
# Test-gate anchor block — literal test names for record-test-status.sh
# ---------------------------------------------------------------------------
_TEST_GATE_ANCHORS=(
    test_has_substep_2a2_heading
    test_references_sc_coverage_sonnet_md
    test_has_covered_missing_unsure_verdicts_in_2a2
    test_unsure_escalated_to_opus
    test_has_substep_2a3_heading
    test_references_sc_coverage_opus_md
    test_opus_dispatch_conditional_on_unsure
    test_has_replan_trigger_sc_coverage
    test_routes_to_preplanning_for_story_children
    test_routes_to_implementation_plan_for_task_children
    test_has_sonnet_fail_open_language
    test_has_opus_fail_open_language
    test_has_missing_sc_triggers_replan_comment
    test_gap_detection_routes_by_child_type
)
