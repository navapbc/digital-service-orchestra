#!/usr/bin/env bash
# tests/reviewers/test-agent-clarity-epic-calibration.sh
# TDD structural validation tests for epic-level calibration of agent-clarity.md.
#
# Tests:
#  (a) test_dimensions_reference_planners    — dimension defs reference planners/story decomposition,
#                                              not "developer agent...would build the right thing"
#  (b) test_anti_pattern_instruction_present — Instructions section prohibits penalizing missing file
#                                              paths, shell commands, and implementation details (SC3)
#  (c) test_ambiguity_penalization_present   — reviewer penalizes vague outcomes, undefined jargon,
#                                              missing edge case coverage (SC4)
#  (d) test_copies_identical                 — brainstorm and roadmap copies are byte-identical
#  (e) test_scoring_scale_preserved          — scoring scale table and JSON output format are preserved
#
# Usage: bash tests/reviewers/test-agent-clarity-epic-calibration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED STATE: These tests currently fail because agent-clarity.md still contains old
# "developer agent" calibration and lacks epic-level anti-pattern instructions.
# They will pass (GREEN) after agent-clarity.md is rewritten for epic-level evaluation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_MD="$PLUGIN_ROOT/plugins/dso/skills/shared/docs/reviewers/agent-clarity.md"
BRAINSTORM_MD="$SHARED_MD"
ROADMAP_MD="$SHARED_MD"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-agent-clarity-epic-calibration.sh ==="

# ── test_dimensions_reference_planners ───────────────────────────────────────
# (a) Dimension definitions must reference planners/story decomposition, NOT
#     "developer agent...would build the right thing" (old implementation-level framing).
test_dimensions_reference_planners() {
    _snapshot_fail
    local _content
    _content=$(cat "$BRAINSTORM_MD")

    # Must NOT contain the old developer-agent framing
    local _has_old_framing=0
    if echo "$_content" | grep -qF 'developer agent'; then
        _has_old_framing=1
    fi
    assert_eq "test_dimensions_reference_planners: must NOT contain 'developer agent'" "0" "$_has_old_framing"

    # Must contain reference to planner-level concerns (planners or story decomposition)
    local _has_planner_ref=0
    if echo "$_content" | grep -qiE 'planner|story decomposition|decompose'; then
        _has_planner_ref=1
    fi
    assert_eq "test_dimensions_reference_planners: must reference planners/story decomposition" "1" "$_has_planner_ref"

    assert_pass_if_clean "test_dimensions_reference_planners"
}

# ── test_anti_pattern_instruction_present ────────────────────────────────────
# (b) The Instructions section must contain guidance prohibiting penalization of
#     missing file paths, shell commands, and implementation details (SC3).
test_anti_pattern_instruction_present() {
    _snapshot_fail
    local _content
    _content=$(cat "$BRAINSTORM_MD")

    # Must NOT penalize missing file paths
    local _has_anti_filepath=0
    if echo "$_content" | grep -qiE 'do not penali[sz]e.*file path|file path.*not.*penali[sz]|not.*penali[sz]e.*file'; then
        _has_anti_filepath=1
    fi
    assert_eq "test_anti_pattern_instruction_present: must instruct not to penalize missing file paths" "1" "$_has_anti_filepath"

    # Must NOT penalize missing shell commands or implementation details
    local _has_anti_impl=0
    if echo "$_content" | grep -qiE 'do not penali[sz]e.*shell|do not penali[sz]e.*implementation|implementation detail.*not.*penali[sz]|not.*penali[sz]e.*(shell|implementation)'; then
        _has_anti_impl=1
    fi
    assert_eq "test_anti_pattern_instruction_present: must instruct not to penalize missing shell commands/implementation details" "1" "$_has_anti_impl"

    assert_pass_if_clean "test_anti_pattern_instruction_present"
}

# ── test_ambiguity_penalization_present ──────────────────────────────────────
# (c) The reviewer must be instructed to penalize genuinely ambiguous specs:
#     vague outcomes, undefined jargon, and missing edge case coverage (SC4).
test_ambiguity_penalization_present() {
    _snapshot_fail
    local _content
    _content=$(cat "$BRAINSTORM_MD")

    # Must contain reference to penalizing vague outcomes or undefined jargon or edge cases
    local _has_vague_outcomes=0
    if echo "$_content" | grep -qiE 'vague outcome|undefined jargon|edge case'; then
        _has_vague_outcomes=1
    fi
    assert_eq "test_ambiguity_penalization_present: must penalize vague outcomes/undefined jargon/missing edge cases" "1" "$_has_vague_outcomes"

    assert_pass_if_clean "test_ambiguity_penalization_present"
}

# ── test_copies_identical ────────────────────────────────────────────────────
# (d) The brainstorm and roadmap copies of agent-clarity.md must be byte-identical.
test_copies_identical() {
    _snapshot_fail

    local _are_identical=0
    if cmp -s "$BRAINSTORM_MD" "$ROADMAP_MD"; then
        _are_identical=1
    fi
    assert_eq "test_copies_identical: brainstorm and roadmap copies must be byte-identical" "1" "$_are_identical"

    assert_pass_if_clean "test_copies_identical"
}

# ── test_scoring_scale_preserved ─────────────────────────────────────────────
# (e) The scoring scale table and JSON output format must be preserved.
test_scoring_scale_preserved() {
    _snapshot_fail
    local _content
    _content=$(cat "$BRAINSTORM_MD")

    # Scoring scale table must be present (check for scale header and at least scores 1 and 5)
    local _has_scale_table=0
    if echo "$_content" | grep -qF '| Score |' && echo "$_content" | grep -qF '| 5 |' && echo "$_content" | grep -qF '| 1 |'; then
        _has_scale_table=1
    fi
    assert_eq "test_scoring_scale_preserved: scoring scale table must be preserved" "1" "$_has_scale_table"

    # JSON output block must be present with "dimensions" key
    local _has_json_output=0
    if echo "$_content" | grep -qF '"dimensions"'; then
        _has_json_output=1
    fi
    assert_eq "test_scoring_scale_preserved: JSON output format with 'dimensions' must be preserved" "1" "$_has_json_output"

    # perspective label "Agent Clarity" must be preserved
    local _has_perspective=0
    if echo "$_content" | grep -qF '"Agent Clarity"'; then
        _has_perspective=1
    fi
    assert_eq "test_scoring_scale_preserved: perspective label 'Agent Clarity' must be preserved" "1" "$_has_perspective"

    assert_pass_if_clean "test_scoring_scale_preserved"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_dimensions_reference_planners
test_anti_pattern_instruction_present
test_ambiguity_penalization_present
test_copies_identical
test_scoring_scale_preserved

print_summary
