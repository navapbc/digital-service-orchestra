#!/usr/bin/env bash
# tests/skills/test-sprint-layer-overlap-promotion.sh
# Structural boundary test for sprint SKILL.md Step D: post-planning
# file-overlap layer promotion.
#
# Verifies that sprint SKILL.md contains the behavioral contract for detecting
# file-level overlap between same-layer stories and promoting overlapping stories
# to the next layer AFTER implementation-plan completes — preventing the mass
# merge conflicts that occur when parallel stories modify the same files.
#
# Bug: 6058-865c (layer stratification does not detect file-level overlap)
#
# Tests:
#   test_has_step_d_heading
#   test_collects_file_sets_per_story
#   test_detects_pairwise_overlaps
#   test_emits_file_overlap_signal
#   test_promotes_to_next_layer
#   test_adds_dependency_link
#   test_relogs_updated_assignment
#   test_handles_equal_priority
#   test_single_story_skip_condition
#   test_step_d_fires_after_impl_plan_per_layer
#
# RED phase: all tests fail if Step D is absent from SKILL.md.
# GREEN phase: pass after Step D is present.
#
# Usage:
#   bash tests/skills/test-sprint-layer-overlap-promotion.sh

set -uo pipefail
# REVIEW-DEFENSE: set -uo pipefail without -e is consistent with all other
# test files in tests/skills/. -e is intentionally omitted: assert.sh tracks
# failures via counters and print_summary provides the final exit code.
# Adding -e would exit on the first assert_eq failure, suppressing remaining
# test output.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-layer-overlap-promotion.sh ==="

# ---------------------------------------------------------------------------
# test_has_step_d_heading
# SKILL.md must contain a "Step D" heading within the Dependency Layer
# Stratification section. The heading is the structural anchor for the
# file-overlap detection behavior.
# ---------------------------------------------------------------------------
test_has_step_d_heading() {
    local match=0
    match=$(grep -cE "Step D" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_has_step_d_heading: Step D heading present in sprint SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_collects_file_sets_per_story
# Step D must instruct the agent to collect the set of files per story by
# reading task file-impact tables (## Files to Modify or ## File Impact).
# This is the data-collection boundary the behavior depends on.
# ---------------------------------------------------------------------------
test_collects_file_sets_per_story() {
    local match=0
    # Look for language about collecting file sets from task content, within a
    # Step D or file-overlap context. Must reference "Files to Modify" or
    # "File Impact" — the structural section headers used in implementation-plan tasks.
    match=$(grep -cEi "Files to Modify|File Impact" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_collects_file_sets_per_story: SKILL.md references '## Files to Modify' or '## File Impact' as data source" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_detects_pairwise_overlaps
# Step D must instruct pairwise intersection comparison between stories in the
# same layer. The contract requires the overlap to be detected before the next
# layer executes.
# ---------------------------------------------------------------------------
test_detects_pairwise_overlaps() {
    local match=0
    # Look for pairwise comparison language or intersection logic within a
    # file-overlap/Step D context.
    match=$(grep -cEi "pairwise|pair of stories|overlap.*story|story.*overlap|intersection" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_detects_pairwise_overlaps: pairwise/intersection language present for file-overlap detection" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_emits_file_overlap_signal
# Step D must produce a FILE_OVERLAP log signal when overlap is detected.
# This signal is the observable contract boundary — sprint SKILL.md must
# specify what the agent emits so the overlap can be traced in execution logs.
# ---------------------------------------------------------------------------
test_emits_file_overlap_signal() {
    local match=0
    match=$(grep -cE "FILE_OVERLAP" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_emits_file_overlap_signal: FILE_OVERLAP signal present in sprint SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_promotes_to_next_layer
# Step D must reassign the overlapping story to the next layer (current_layer + 1),
# not to an arbitrary future layer. This is the core behavioral contract.
# ---------------------------------------------------------------------------
test_promotes_to_next_layer() {
    local match=0
    # Look for language about promoting/reassigning to the next layer.
    match=$(grep -cEi "next layer|current_layer.*1|layer.*\+ *1|Reassign.*layer|promot.*layer" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_promotes_to_next_layer: next-layer promotion language present in sprint SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_adds_dependency_link
# When a story is promoted due to overlap, Step D must add a ticket dependency
# link from the promoted story to the higher-priority story. This ensures the
# dependency ordering is persisted in the ticket system, not just in-memory.
# ---------------------------------------------------------------------------
test_adds_dependency_link() {
    local match=0
    # Look for ticket link command in the file-overlap/Step D context.
    # The link command must add a depends_on relationship.
    local step_d_section
    step_d_section=$(grep -A 20 "Step D" "$SKILL_FILE" 2>/dev/null) || step_d_section=""
    if [[ -n "$step_d_section" ]]; then
        match=$(echo "$step_d_section" | grep -cEi "ticket.*link.*depends_on|depends_on") || match=0
        [[ "$match" -gt 0 ]] && match=1
    fi
    assert_eq "test_adds_dependency_link: ticket link depends_on emitted for promoted story in Step D" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_relogs_updated_assignment
# After applying promotions, Step D must re-log the updated layer assignment.
# This ensures the audit trail reflects the final assignment after overlap
# resolution, not just the initial topological sort.
# ---------------------------------------------------------------------------
test_relogs_updated_assignment() {
    local match=0
    # Look for re-log / updated assignment language in overlap context.
    match=$(grep -cEi "after.*overlap|overlap.*check|updated.*layer|layer.*after.*overlap|Dependency layers after" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_relogs_updated_assignment: re-log updated layer assignment after overlap check present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_handles_equal_priority
# Step D must specify behavior when two stories have equal priority. The
# contract requires a deterministic tiebreak (first-in-layer by creation order).
# ---------------------------------------------------------------------------
test_handles_equal_priority() {
    local match=0
    # Look for equal priority tiebreak language within file-overlap/Step D context.
    match=$(grep -cEi "equal.*priority|priority.*equal|same.*priority|tiebreak|first.*layer.*list|creation order" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_handles_equal_priority: equal-priority tiebreak behavior specified in sprint SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_single_story_skip_condition
# Step D must specify a skip condition: when a layer contains only one story,
# the overlap check is skipped (no pairs to compare). This prevents spurious
# work and log noise on single-story layers.
# ---------------------------------------------------------------------------
test_single_story_skip_condition() {
    local match=0
    # Look for single-story skip condition language near Step D context.
    match=$(grep -cEi "only 1 story|only one story|single story.*skip|1 story.*skip|skip.*1 story|layer.*1 story" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_single_story_skip_condition: single-story layer skip condition present in sprint SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_step_d_fires_after_impl_plan_per_layer
# Step D must fire per-layer, after implementation-plan completes for the
# whole layer and before the next layer begins. This timing contract prevents
# the overlap check from running before file-impact data is available.
# ---------------------------------------------------------------------------
test_step_d_fires_after_impl_plan_per_layer() {
    local match=0
    # Look for language that anchors Step D after impl-plan completion, per layer.
    match=$(grep -cEi "after.*implementation-plan.*layer|per layer.*after|fires.*per layer|per layer.*before next|before.*next layer|after.*impl.*plan.*completes.*layer|completes for.*layer" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_step_d_fires_after_impl_plan_per_layer: Step D per-layer timing (after impl-plan, before next layer) present in SKILL.md" "1" "$match"
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
test_has_step_d_heading
test_collects_file_sets_per_story
test_detects_pairwise_overlaps
test_emits_file_overlap_signal
test_promotes_to_next_layer
test_adds_dependency_link
test_relogs_updated_assignment
test_handles_equal_priority
test_single_story_skip_condition
test_step_d_fires_after_impl_plan_per_layer

print_summary

# ---------------------------------------------------------------------------
# Test-gate anchor block — literal test names for record-test-status.sh
# ---------------------------------------------------------------------------
_TEST_GATE_ANCHORS=(
    test_has_step_d_heading
    test_collects_file_sets_per_story
    test_detects_pairwise_overlaps
    test_emits_file_overlap_signal
    test_promotes_to_next_layer
    test_adds_dependency_link
    test_relogs_updated_assignment
    test_handles_equal_priority
    test_single_story_skip_condition
    test_step_d_fires_after_impl_plan_per_layer
)
