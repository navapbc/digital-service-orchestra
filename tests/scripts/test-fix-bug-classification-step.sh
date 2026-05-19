#!/usr/bin/env bash
# tests/scripts/test-fix-bug-classification-step.sh
# Structural assertion tests for the Bug Classification step in fix-bug/SKILL.md.
# Task b92e-e370-4edb-43ed (RED phase): all tests fail until the step is added.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: Bug Classification section exists
# ---------------------------------------------------------------------------
test_bug_classification_section_exists() {
    if grep -qi "Bug Classification" "$SKILL_FILE"; then
        pass "test_bug_classification_section_exists"
    else
        fail "test_bug_classification_section_exists — 'Bug Classification' not found in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Test 2: Agent dispatch reference to bug-classifier-haiku
# ---------------------------------------------------------------------------
test_classifier_agent_dispatched() {
    if grep -q "bug-classifier-haiku" "$SKILL_FILE"; then
        pass "test_classifier_agent_dispatched"
    else
        fail "test_classifier_agent_dispatched — 'bug-classifier-haiku' not found in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Test 3: Mandatory trigger — 'Fixed:' appears in classification context
# ---------------------------------------------------------------------------
test_fixed_reason_in_classification_context() {
    if grep -q "Fixed:" "$SKILL_FILE"; then
        pass "test_fixed_reason_in_classification_context"
    else
        fail "test_fixed_reason_in_classification_context — 'Fixed:' not found in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Test 4: Skip condition — 'Escalated to user:' appears as a skip condition
# ---------------------------------------------------------------------------
test_escalated_to_user_skip_condition() {
    if grep -q "Escalated to user:" "$SKILL_FILE"; then
        pass "test_escalated_to_user_skip_condition"
    else
        fail "test_escalated_to_user_skip_condition — 'Escalated to user:' not found in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Test 5: Failure tag 1 — bug-type-uncategorized
# ---------------------------------------------------------------------------
test_failure_tag_uncategorized() {
    if grep -q "bug-type-uncategorized" "$SKILL_FILE"; then
        pass "test_failure_tag_uncategorized"
    else
        fail "test_failure_tag_uncategorized — 'bug-type-uncategorized' not found in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Test 6: Failure tag 2 — bug-type-classifier-failed
# ---------------------------------------------------------------------------
test_failure_tag_classifier_failed() {
    if grep -q "bug-type-classifier-failed" "$SKILL_FILE"; then
        pass "test_failure_tag_classifier_failed"
    else
        fail "test_failure_tag_classifier_failed — 'bug-type-classifier-failed' not found in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Test 7: MAX_AGENTS exemption present in classification context
# ---------------------------------------------------------------------------
test_max_agents_exemption() {
    # The classification step dispatch must be exempt from the MAX_AGENTS cap.
    # Check for 'exempt' appearing anywhere in the SKILL.md near classification content.
    local exempt_count
    exempt_count=$(grep -c "exempt" "$SKILL_FILE" 2>/dev/null || echo "0")
    # We expect at least one 'exempt' entry that relates to the classification step.
    # A simple presence check suffices — the GREEN phase task will tighten this
    # to verify proximity to the Bug Classification section.
    local class_line
    class_line=$(grep -n "Bug Classification" "$SKILL_FILE" | head -1 | cut -d: -f1 || echo "")
    if [ -z "$class_line" ]; then
        fail "test_max_agents_exemption — 'Bug Classification' section not found; cannot check exemption proximity"
        return
    fi
    local start=$(( class_line - 5 ))
    local end=$(( class_line + 30 ))
    [ "$start" -lt 1 ] && start=1
    if sed -n "${start},${end}p" "$SKILL_FILE" | grep -q "exempt"; then
        pass "test_max_agents_exemption"
    else
        fail "test_max_agents_exemption — 'exempt' not found near Bug Classification section in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Test 8: Positional check — Bug Classification appears after Phase G and before Phase H
# ---------------------------------------------------------------------------
test_bug_classification_position() {
    local line_phase_g line_bug_class line_phase_h

    line_phase_g=$(grep -n "## Phase G" "$SKILL_FILE" | head -1 | cut -d: -f1 || echo "")
    line_bug_class=$(grep -n "Bug Classification" "$SKILL_FILE" | head -1 | cut -d: -f1 || echo "")
    line_phase_h=$(grep -n "## Phase H" "$SKILL_FILE" | head -1 | cut -d: -f1 || echo "")

    if [ -z "$line_phase_g" ]; then
        fail "test_bug_classification_position — '## Phase G' not found in fix-bug/SKILL.md"
        return
    fi
    if [ -z "$line_phase_h" ]; then
        fail "test_bug_classification_position — '## Phase H' not found in fix-bug/SKILL.md"
        return
    fi
    if [ -z "$line_bug_class" ]; then
        fail "test_bug_classification_position — 'Bug Classification' not found in fix-bug/SKILL.md (cannot check position)"
        return
    fi

    if [ "$line_bug_class" -gt "$line_phase_g" ] && [ "$line_bug_class" -lt "$line_phase_h" ]; then
        pass "test_bug_classification_position"
    else
        fail "test_bug_classification_position — 'Bug Classification' (line $line_bug_class) must appear after Phase G (line $line_phase_g) and before Phase H (line $line_phase_h)"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_bug_classification_section_exists
test_classifier_agent_dispatched
test_fixed_reason_in_classification_context
test_escalated_to_user_skip_condition
test_failure_tag_uncategorized
test_failure_tag_classifier_failed
test_max_agents_exemption
test_bug_classification_position

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
