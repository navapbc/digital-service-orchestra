#!/usr/bin/env bash
# tests/scripts/test-sprint-primary-ticket-model.sh
# RED tests for the sprint SKILL.md primary ticket model (SC1, SC4, SC5).
#
# Tests verify structural and routing constraints — they check what MUST be
# present in plugins/dso/skills/sprint/SKILL.md after the primary ticket model
# is implemented.
#
# Test cases (15+):
#
# Terminology (negative constraints — old epic-selection language must be absent)
#   test_no_epic_selection_header         — "## Phase 1: Initialization & Epic Selection" absent
#   test_no_post_epic_validation          — "## Phase 6: Post-Epic Validation" absent
#
# Terminology (positive constraints — new primary ticket language must be present)
#   test_primary_ticket_in_phase1         — "Primary Ticket Selection" present
#   test_primary_ticket_in_phase6         — "Primary Ticket" present in Phase 6 header
#   test_primary_ticket_id_var            — "primary_ticket_id" or "primary-ticket-id" variable present
#
# Clarity Gate (behavioral structure tests in Phase 1)
#   test_clarity_gate_section             — "clarity gate" or "Clarity Gate" in Phase 1
#   test_clarity_gate_layer1              — "ticket-clarity-check" referenced in Phase 1
#   test_clarity_gate_layer2              — "scope_certainty" referenced as second gate
#   test_clarity_gate_layer3              — User escalation section with AskUserQuestion
#
# Routing (SC1 positive structure tests in Phase 1)
#   test_bug_routing                      — Phase 1 contains "fix-bug" dispatch for bug-typed tickets
#   test_non_epic_routing                 — Phase 1 contains complexity evaluation for non-epic types
#   test_epic_routing_preserved           — Preplanning gate still references "/dso:preplanning"
#
# User Escalation (SC4)
#   test_escalation_fixbug_option         — fix-bug option present in escalation section
#   test_escalation_brainstorm_option     — brainstorm option present
#   test_escalation_proceed_option        — proceed option present
#
# CHECKPOINT (SC5)
#   test_checkpoint_semantic_format       — "CHECKPOINT:" prefix pattern present
#
# Prompt Templates (SC5)
#   test_prompt_primary_ticket_id         — red-task-escalation.md and ci-failure-validation-state.md
#                                           reference primary_ticket_id
#
# Usage: bash tests/scripts/test-sprint-primary-ticket-model.sh
# RED STATE: Most tests currently fail because the sprint SKILL.md has not yet
# been updated to implement the primary ticket model. They will pass (GREEN)
# after the implementation task has updated SKILL.md and the prompt templates.

# NOTE: -e intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
RED_TASK_ESCALATION="$REPO_ROOT/plugins/dso/skills/sprint/prompts/red-task-escalation.md"
CI_FAILURE_STATE="$REPO_ROOT/plugins/dso/skills/sprint/prompts/ci-failure-validation-state.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-primary-ticket-model.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

# _count_in_file <pattern> <file>
# Returns count of matching lines in file (0 on not found or error).
# NOTE: grep -c exits 1 when no match but still prints "0" — do NOT add || echo "0"
# as that produces "0\n0" and causes arithmetic errors in [[ ... -gt 0 ]].
_count_in_file() {
    local pattern="$1" file="$2"
    local n=0
    n=$(grep -c "$pattern" "$file" 2>/dev/null) || n=0
    echo "${n:-0}"
}

# _count_in_section <start_pattern> <end_pattern> <search_pattern> <file>
# Counts occurrences of search_pattern within lines from start to end pattern.
_count_in_section() {
    local start="$1" end="$2" search="$3" file="$4"
    local n=0
    n=$(awk "/$start/,/$end/" "$file" 2>/dev/null | grep -c "$search" 2>/dev/null) || n=0
    echo "${n:-0}"
}

# ── Terminology: negative constraints ────────────────────────────────────────

# test_no_epic_selection_header
# The old "## Phase 1: Initialization & Epic Selection" heading must NOT appear.
# After the primary ticket model is implemented, Phase 1 is renamed to use
# "Primary Ticket" language.
test_no_epic_selection_header() {
    _snapshot_fail
    local match=0
    match=$(_count_in_file "## Phase 1: Initialization & Epic Selection" "$SKILL_FILE")
    assert_eq "test_no_epic_selection_header: old Phase 1 header absent" "0" "$match"
    assert_pass_if_clean "test_no_epic_selection_header"
}

# test_no_post_epic_validation
# The old "## Phase 6: Post-Epic Validation" heading must NOT appear.
# After the primary ticket model, Phase 6 is renamed to include "Primary Ticket" language.
test_no_post_epic_validation() {
    _snapshot_fail
    local match=0
    match=$(_count_in_file "## Phase 6: Post-Epic Validation" "$SKILL_FILE")
    assert_eq "test_no_post_epic_validation: old Phase 6 header absent" "0" "$match"
    assert_pass_if_clean "test_no_post_epic_validation"
}

# ── Terminology: positive constraints ────────────────────────────────────────

# test_primary_ticket_in_phase1
# "Primary Ticket Selection" must appear as a section heading in Phase 1.
test_primary_ticket_in_phase1() {
    _snapshot_fail
    local match=0
    match=$(_count_in_file "Primary Ticket Selection" "$SKILL_FILE")
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_primary_ticket_in_phase1: Primary Ticket Selection heading present" "1" "$match"
    assert_pass_if_clean "test_primary_ticket_in_phase1"
}

# test_primary_ticket_in_phase6
# "Primary Ticket" must appear in the Phase 6 heading.
test_primary_ticket_in_phase6() {
    _snapshot_fail
    local match=0
    match=$(grep -c "## Phase 6:.*Primary Ticket" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_primary_ticket_in_phase6: Primary Ticket present in Phase 6 heading" "1" "$match"
    assert_pass_if_clean "test_primary_ticket_in_phase6"
}

# test_primary_ticket_id_var
# The variable "primary_ticket_id" or "primary-ticket-id" must appear in SKILL.md.
test_primary_ticket_id_var() {
    _snapshot_fail
    local match=0
    match=$(grep -cE "primary[_-]ticket[_-]id" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_primary_ticket_id_var: primary_ticket_id variable present" "1" "$match"
    assert_pass_if_clean "test_primary_ticket_id_var"
}

# ── Clarity Gate ─────────────────────────────────────────────────────────────

# test_clarity_gate_section
# "clarity gate" or "Clarity Gate" must appear within the SKILL.md file.
test_clarity_gate_section() {
    _snapshot_fail
    local match=0
    match=$(grep -ci "clarity gate" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_clarity_gate_section: clarity gate section present" "1" "$match"
    assert_pass_if_clean "test_clarity_gate_section"
}

# test_clarity_gate_layer1
# The script "ticket-clarity-check" must be referenced within the Phase 1 section.
test_clarity_gate_layer1() {
    _snapshot_fail
    local match=0
    match=$(_count_in_section "Phase 1:" "Phase 2:" "ticket-clarity-check" "$SKILL_FILE")
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_clarity_gate_layer1: ticket-clarity-check referenced in Phase 1" "1" "$match"
    assert_pass_if_clean "test_clarity_gate_layer1"
}

# test_clarity_gate_layer2
# "scope_certainty" must appear in the SKILL.md as the second gate variable.
test_clarity_gate_layer2() {
    _snapshot_fail
    local match=0
    match=$(_count_in_file "scope_certainty" "$SKILL_FILE")
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_clarity_gate_layer2: scope_certainty referenced as second gate" "1" "$match"
    assert_pass_if_clean "test_clarity_gate_layer2"
}

# test_clarity_gate_layer3
# User escalation with AskUserQuestion must be present in Phase 1's clarity gate section.
test_clarity_gate_layer3() {
    _snapshot_fail
    local match=0
    match=$(_count_in_section "Phase 1:" "Phase 2:" "AskUserQuestion" "$SKILL_FILE")
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_clarity_gate_layer3: AskUserQuestion escalation in Phase 1" "1" "$match"
    assert_pass_if_clean "test_clarity_gate_layer3"
}

# ── Routing (SC1) ─────────────────────────────────────────────────────────────

# test_bug_routing
# Phase 1 must contain routing logic that dispatches fix-bug for bug-typed tickets.
test_bug_routing() {
    _snapshot_fail
    local match=0
    match=$(_count_in_section "Phase 1:" "Phase 2:" "fix-bug" "$SKILL_FILE")
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_bug_routing: fix-bug dispatch in Phase 1 for bug tickets" "1" "$match"
    assert_pass_if_clean "test_bug_routing"
}

# test_non_epic_routing
# Phase 1 must contain complexity evaluation routing for non-epic ticket types.
test_non_epic_routing() {
    _snapshot_fail
    local match=0
    match=$(awk '/Phase 1:/,/Phase 2:/' "$SKILL_FILE" 2>/dev/null | grep -cE "complexity.evaluator|complexity-evaluator|dso:complexity" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_non_epic_routing: complexity evaluation for non-epic types in Phase 1" "1" "$match"
    assert_pass_if_clean "test_non_epic_routing"
}

# test_epic_routing_preserved
# The preplanning gate must still reference "/dso:preplanning" — epic routing
# must not be removed by the primary ticket model change.
test_epic_routing_preserved() {
    _snapshot_fail
    local match=0
    match=$(_count_in_file "/dso:preplanning" "$SKILL_FILE")
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_epic_routing_preserved: /dso:preplanning still referenced" "1" "$match"
    assert_pass_if_clean "test_epic_routing_preserved"
}

# ── User Escalation (SC4) ─────────────────────────────────────────────────────

# test_escalation_fixbug_option
# The user escalation section must present "fix-bug" as an option when clarity
# is low and ticket type is ambiguous.
test_escalation_fixbug_option() {
    _snapshot_fail
    local match=0
    # Look for fix-bug within an escalation context anywhere in the file
    match=$(awk '/[Ee]scalat/,/---/' "$SKILL_FILE" 2>/dev/null | grep -ci "fix.bug" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_escalation_fixbug_option: fix-bug option in escalation section" "1" "$match"
    assert_pass_if_clean "test_escalation_fixbug_option"
}

# test_escalation_brainstorm_option
# The user escalation section must present "brainstorm" as an option.
test_escalation_brainstorm_option() {
    _snapshot_fail
    local match=0
    match=$(awk '/[Ee]scalat/,/---/' "$SKILL_FILE" 2>/dev/null | grep -ci "brainstorm" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_escalation_brainstorm_option: brainstorm option in escalation section" "1" "$match"
    assert_pass_if_clean "test_escalation_brainstorm_option"
}

# test_escalation_proceed_option
# The user escalation section must present a "proceed" option to allow the user
# to continue with the current ticket type despite low clarity.
test_escalation_proceed_option() {
    _snapshot_fail
    local match=0
    match=$(awk '/[Ee]scalat/,/---/' "$SKILL_FILE" 2>/dev/null | grep -ci "proceed" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_escalation_proceed_option: proceed option in escalation section" "1" "$match"
    assert_pass_if_clean "test_escalation_proceed_option"
}

# ── CHECKPOINT (SC5) ──────────────────────────────────────────────────────────

# test_checkpoint_semantic_format
# The SKILL.md must use "CHECKPOINT:" semantic prefix in its phase progress
# tracking — specifically the colon-delimited key-value form "CHECKPOINT: <value>"
# that the per-worktree-review-commit workflow emits for structured phase state.
test_checkpoint_semantic_format() {
    _snapshot_fail
    local match=0
    match=$(_count_in_file "CHECKPOINT:" "$SKILL_FILE")
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_checkpoint_semantic_format: CHECKPOINT: prefix pattern present" "1" "$match"
    assert_pass_if_clean "test_checkpoint_semantic_format"
}

# ── Prompt Templates (SC5) ────────────────────────────────────────────────────

# test_prompt_primary_ticket_id
# Both red-task-escalation.md and ci-failure-validation-state.md must reference
# primary_ticket_id so sub-agents can propagate the primary ticket context.
test_prompt_primary_ticket_id() {
    _snapshot_fail

    local match_red=0
    match_red=$(grep -cE "primary[_-]ticket[_-]id" "$RED_TASK_ESCALATION" 2>/dev/null) || match_red=0
    [[ "$match_red" -gt 0 ]] && match_red=1

    local match_ci=0
    match_ci=$(grep -cE "primary[_-]ticket[_-]id" "$CI_FAILURE_STATE" 2>/dev/null) || match_ci=0
    [[ "$match_ci" -gt 0 ]] && match_ci=1

    # Both files must have the reference — combine into a single assertion
    local combined=0
    [[ "$match_red" -eq 1 && "$match_ci" -eq 1 ]] && combined=1

    assert_eq "test_prompt_primary_ticket_id: primary_ticket_id in red-task-escalation.md and ci-failure-validation-state.md" "1" "$combined"
    assert_pass_if_clean "test_prompt_primary_ticket_id"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_no_epic_selection_header
test_no_post_epic_validation
test_primary_ticket_in_phase1
test_primary_ticket_in_phase6
test_primary_ticket_id_var
test_clarity_gate_section
test_clarity_gate_layer1
test_clarity_gate_layer2
test_clarity_gate_layer3
test_bug_routing
test_non_epic_routing
test_epic_routing_preserved
test_escalation_fixbug_option
test_escalation_brainstorm_option
test_escalation_proceed_option
test_checkpoint_semantic_format
test_prompt_primary_ticket_id

print_summary
