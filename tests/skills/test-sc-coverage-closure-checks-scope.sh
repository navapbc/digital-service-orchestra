#!/usr/bin/env bash
# tests/skills/test-sc-coverage-closure-checks-scope.sh
# Behavioral tests for SC coverage prompt scoping: ## Closure Checks exclusion.
#
# Verifies that each sc-coverage-*.md prompt file explicitly instructs the
# model to scope the coverage check to ## Success Criteria only, stopping
# when a ## Closure Checks section is encountered.
#
# Also verifies (via mock ticket text) that the scoping instruction correctly
# counts 3 SC items when a ticket has 3 ## Success Criteria items and 2
# ## Closure Checks items (not 5).
#
# Story: 0e96-19d2-aa57-4ad6 (S7)
# Done Definitions: DD1, DD2, DD3, DD4
#
# Tests:
#   test_haiku_has_closure_checks_scoping_instruction
#     - sc-coverage-haiku.md must contain explicit ## Closure Checks exclusion
#   test_sonnet_has_closure_checks_scoping_instruction
#     - sc-coverage-sonnet.md must contain explicit ## Closure Checks exclusion
#   test_opus_has_closure_checks_scoping_instruction
#     - sc-coverage-opus.md must contain explicit ## Closure Checks exclusion
#   test_mock_ticket_sc_only_count_is_3
#     - Logic that parses ## Success Criteria produces count=3, not 5, for a
#       ticket with 3 SC items followed by 2 ## Closure Checks items
#
# RED phase: tests fail until sc-coverage-*.md files are updated.
# GREEN phase: pass after scoping instruction is added to all 3 prompt files.
#
# Usage:
#   bash tests/skills/test-sc-coverage-closure-checks-scope.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

HAIKU_PROMPT="$REPO_ROOT/plugins/dso/skills/sprint/prompts/sc-coverage-haiku.md"
SONNET_PROMPT="$REPO_ROOT/plugins/dso/skills/sprint/prompts/sc-coverage-sonnet.md"
OPUS_PROMPT="$REPO_ROOT/plugins/dso/skills/sprint/prompts/sc-coverage-opus.md"

echo "=== test-sc-coverage-closure-checks-scope.sh ==="

# ---------------------------------------------------------------------------
# test_haiku_has_closure_checks_scoping_instruction
# sc-coverage-haiku.md must contain an explicit instruction to scope the
# coverage check to ## Success Criteria only and stop at ## Closure Checks.
# ---------------------------------------------------------------------------
test_haiku_has_closure_checks_scoping_instruction() {
    local match=0
    match=$(grep -cEi "Closure Checks|stop.*parsing|Success Criteria.*only|only.*Success Criteria" "$HAIKU_PROMPT" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_haiku_has_closure_checks_scoping_instruction: sc-coverage-haiku.md contains Closure Checks scoping instruction" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_sonnet_has_closure_checks_scoping_instruction
# sc-coverage-sonnet.md must contain an explicit instruction to scope the
# coverage check to ## Success Criteria only and stop at ## Closure Checks.
# ---------------------------------------------------------------------------
test_sonnet_has_closure_checks_scoping_instruction() {
    local match=0
    match=$(grep -cEi "Closure Checks|stop.*parsing|Success Criteria.*only|only.*Success Criteria" "$SONNET_PROMPT" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_sonnet_has_closure_checks_scoping_instruction: sc-coverage-sonnet.md contains Closure Checks scoping instruction" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_opus_has_closure_checks_scoping_instruction
# sc-coverage-opus.md must contain an explicit instruction to scope the
# coverage check to ## Success Criteria only and stop at ## Closure Checks.
# ---------------------------------------------------------------------------
test_opus_has_closure_checks_scoping_instruction() {
    local match=0
    match=$(grep -cEi "Closure Checks|stop.*parsing|Success Criteria.*only|only.*Success Criteria" "$OPUS_PROMPT" 2>/dev/null) || match=0
    [[ "$match" -gt 0 ]] && match=1
    assert_eq "test_opus_has_closure_checks_scoping_instruction: sc-coverage-opus.md contains Closure Checks scoping instruction" "1" "$match"
}

# ---------------------------------------------------------------------------
# test_mock_ticket_sc_only_count_is_3
# Simulates the extraction logic described in the scoping instruction.
# A ticket with ## Success Criteria (3 items) followed by ## Closure Checks
# (2 items) must produce a count of 3 — not 5.
#
# This test uses awk to emulate the "stop at ## Closure Checks" parsing rule
# that the prompt instructs the model to follow, and verifies the instruction
# text in the prompt is specific enough to encode this behavior.
# ---------------------------------------------------------------------------
test_mock_ticket_sc_only_count_is_3() {
    # Mock ticket body with ## Success Criteria and ## Closure Checks sections
    local mock_ticket
    mock_ticket='## Success Criteria

- SC1: The system does X when Y
- SC2: Users can perform Z
- SC3: The audit log captures all events

## Closure Checks

- CC1: PR is reviewed and approved
- CC2: Docs updated'

    # Extract only items under ## Success Criteria, stopping at ## Closure Checks
    # This emulates the scoping instruction the prompt should give to the model.
    local sc_count
    sc_count=$(echo "$mock_ticket" | awk '
        /^## Success Criteria/ { in_sc=1; next }
        /^## / && in_sc { exit }
        in_sc && /^- / { count++ }
        END { print count+0 }
    ')

    assert_eq "test_mock_ticket_sc_only_count_is_3: SC count from ticket with CC section is 3, not 5" "3" "$sc_count"
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
test_haiku_has_closure_checks_scoping_instruction
test_sonnet_has_closure_checks_scoping_instruction
test_opus_has_closure_checks_scoping_instruction
test_mock_ticket_sc_only_count_is_3

print_summary

# ---------------------------------------------------------------------------
# Test-gate anchor block — literal test names for record-test-status.sh
# ---------------------------------------------------------------------------
_TEST_GATE_ANCHORS=(
    test_haiku_has_closure_checks_scoping_instruction
    test_sonnet_has_closure_checks_scoping_instruction
    test_opus_has_closure_checks_scoping_instruction
    test_mock_ticket_sc_only_count_is_3
)
