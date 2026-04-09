#!/usr/bin/env bash
# tests/skills/test-sprint-epic-selection-display.sh
# Structural tests for sprint SKILL.md epic selection display behavior.
#
# Verifies that Phase 1 steps 2-3 contain explicit prohibition language
# preventing the orchestrator from passing epics as AskUserQuestion options
# and requiring visible text output before the question prompt.
#
# Bugs: 1896-aae8, 49dd-ddee
#
# Tests:
#   test_epic_selection_prohibits_ask_options
#     - SKILL.md must contain language prohibiting passing epics as
#       AskUserQuestion options (the options field is limited to 4 items)
#   test_epic_selection_text_output_required
#     - SKILL.md must explicitly state that text output is required before
#       invoking AskUserQuestion
#
# RED phase: both tests fail until Phase 1 steps 2-3 are strengthened.
# GREEN phase: pass after prohibition language is added.
#
# Usage:
#   bash tests/skills/test-sprint-epic-selection-display.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-epic-selection-display.sh ==="

# ---------------------------------------------------------------------------
# test_epic_selection_prohibits_ask_options
# The Phase 1 "If No Primary Ticket ID Provided" section must contain an
# explicit prohibition on passing epics as `options` to AskUserQuestion.
# The orchestrator must NOT use AskUserQuestion options for epic selection
# because options is capped at 4 items and cannot display blocked epics or
# the hidden-count note.
# ---------------------------------------------------------------------------
test_epic_selection_prohibits_ask_options() {
    local match=0
    # Look for a prohibition on using AskUserQuestion options for the epic list
    match=$(grep -cEi "do not pass.*options|NOT.*options.*AskUserQuestion|options.*field.*limit|do not use.*options.*epic" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_epic_selection_prohibits_ask_options: prohibition on AskUserQuestion options present" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_epic_selection_text_output_required
# The Phase 1 "If No Primary Ticket ID Provided" section must explicitly
# require that the numbered list is output as visible text BEFORE invoking
# AskUserQuestion. This prevents the orchestrator from collapsing both steps
# into a single tool call.
# ---------------------------------------------------------------------------
test_epic_selection_text_output_required() {
    local match=0
    # Look for language requiring visible/text output before AskUserQuestion
    match=$(grep -cEi "visible text|text output.*before|output.*before.*AskUserQuestion|MUST output|print.*before.*ask|BEFORE invoking" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_epic_selection_text_output_required: explicit text-output-first requirement present" "1" "$match"
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
test_epic_selection_prohibits_ask_options
test_epic_selection_text_output_required

# ---------------------------------------------------------------------------
# test_completion_verifier_has_agent_unavailable_fallback (bug 808f-aef3)
# Sprint SKILL.md Step 10a and Phase 6 Step 0.75 must contain explicit
# "agent unavailable" fallback language for dso:completion-verifier dispatch.
# The general-purpose fallback must be documented for "Agent type not found"
# errors (distinct from timeout/JSON technical failure).
# ---------------------------------------------------------------------------
test_completion_verifier_has_agent_unavailable_fallback() {
    local match=0
    match=$(grep -c "Fallback.*agent unavailable" "$SKILL_FILE" 2>/dev/null) || match=0
    [[ "$match" -ge 2 ]] && match=2  # Must appear in both Step 10a and Phase 6 Step 0.75
    assert_eq "test_completion_verifier_has_agent_unavailable_fallback: both Step 10a and Phase 6 Step 0.75 have fallback" "2" "$match"
}

test_completion_verifier_has_agent_unavailable_fallback

print_summary

# ---------------------------------------------------------------------------
# Test-gate anchor block — literal test names for record-test-status.sh
# ---------------------------------------------------------------------------
_TEST_GATE_ANCHORS=(
    test_epic_selection_prohibits_ask_options
    test_epic_selection_text_output_required
    test_completion_verifier_has_agent_unavailable_fallback
)
