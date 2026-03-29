#!/usr/bin/env bash
# tests/scripts/test-debug-everything-interactivity.sh
# Structural metadata validation of debug-everything SKILL.md interactivity
# question at session start and non-interactive deferral behavior.
#
# Verifies that the debug-everything skill:
#   1. Documents asking whether the session is interactive at startup (Phase 1)
#   2. Defers items requiring user input when non-interactive
#   3. Adds INTERACTIVITY_DEFERRED classification comments to deferred bugs
#   4. Auto-defers Phase 2.6 safeguard bugs in non-interactive mode
#   5. Logs COMPLEX_ESCALATION as ticket comment in non-interactive mode
#   6. Propagates the interactivity flag to /dso:fix-bug invocations
#   7. Defers Phase 6 Step 1a file-overlap escalation in non-interactive mode
#   8. Defers Phase 6 Step 1b oscillation-guard escalation in non-interactive mode
#
# Test status:
#   ALL 8 tests are RED — no interactivity mode exists in current SKILL.md.
#
# Exemption: structural metadata validation of prompt file — not executable code.
# RED marker: test_interactivity_question_at_session_start (first RED test — all 8 are RED)
#
# Usage: bash tests/scripts/test-debug-everything-interactivity.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-interactivity.sh ==="

# ============================================================
# RED MARKER BOUNDARY
# ALL 8 tests below are RED — no interactivity mode exists in
# debug-everything/SKILL.md. RED marker in .test-index:
#   [test_interactivity_question_at_session_start]
# ============================================================

# ============================================================
# test_interactivity_question_at_session_start
# SKILL.md must document asking the user whether the session is
# interactive (can pause for input) at the start of Phase 1.
# RED: no interactivity question exists at session start.
# ============================================================
test_interactivity_question_at_session_start() {
    local question_found="missing"

    # Look for a question/check about interactive mode at session start
    # Accept patterns like "interactive session", "ask.*interactive", "Is this session interactive"
    # or a flag/detection step near Phase 1 / Step 1
    if grep -qEi '(ask.*interactive|interactive.*session|is.*session.*interactive|non.?interactive.*mode|interactivity.*flag|INTERACTIVE.*=|interactive.*question)' "$SKILL_FILE" 2>/dev/null; then
        question_found="found"
    fi

    assert_eq "test_interactivity_question_at_session_start: SKILL.md asks about session interactivity at startup" "found" "$question_found"
}

# ============================================================
# test_non_interactive_defers_user_input_items
# When the session is non-interactive, items that require user
# input must be deferred rather than blocking execution.
# RED: no non-interactive deferral mode exists.
# ============================================================
test_non_interactive_defers_user_input_items() {
    local deferral_found="missing"

    # Look for deferral of user-input-requiring items in non-interactive mode
    if grep -qEi '(non.?interactive.*defer|defer.*non.?interactive|non.?interactive.*user input|user input.*non.?interactive|deferr?ed.*non.?interactive|non.?interactive.*block)' "$SKILL_FILE" 2>/dev/null; then
        deferral_found="found"
    fi

    assert_eq "test_non_interactive_defers_user_input_items: non-interactive mode defers items requiring user input" "found" "$deferral_found"
}

# ============================================================
# test_deferred_items_get_classification_comment
# Deferred bugs must receive a classification comment that uses
# the INTERACTIVITY_DEFERRED format, noting which gate flagged them.
# RED: no INTERACTIVITY_DEFERRED comment format exists.
# ============================================================
test_deferred_items_get_classification_comment() {
    local comment_format_found="missing"

    # Look for INTERACTIVITY_DEFERRED format in classification comments
    if grep -q "INTERACTIVITY_DEFERRED" "$SKILL_FILE" 2>/dev/null; then
        comment_format_found="found"
    fi

    assert_eq "test_deferred_items_get_classification_comment: deferred bugs get INTERACTIVITY_DEFERRED classification comment" "found" "$comment_format_found"
}

# ============================================================
# test_interactivity_gates_safeguard_approval
# Non-interactive mode must auto-defer Phase 2.6 safeguard bugs
# instead of presenting approval proposals to the user.
# RED: Phase 2.6 has no interactivity conditional.
# ============================================================
test_interactivity_gates_safeguard_approval() {
    local safeguard_gate_found="missing"

    # Extract Phase 2.6 section and check for non-interactive deferral
    local phase26_section
    phase26_section=$(python3 - "$SKILL_FILE" <<'PYEOF'
import sys, re

skill_file = sys.argv[1]
try:
    content = open(skill_file).read()
except FileNotFoundError:
    sys.exit(0)

# Find Phase 2.6 section (heading with "2.6" or "Safeguard Bug Analysis")
section_match = re.search(
    r'(?m)^#{1,3}\s+.*?(?:2\.6|Safeguard Bug Analysis).*?$(.+?)(?=^#{1,3}\s|\Z)',
    content,
    re.DOTALL
)
if section_match:
    print(section_match.group(1))
PYEOF
)

    if [[ -n "$phase26_section" ]]; then
        if echo "$phase26_section" | grep -qEi '(non.?interactive.*defer|defer.*non.?interactive|interactive.*approval|non.?interactive.*auto.?defer|safeguard.*non.?interactive)'; then
            safeguard_gate_found="found"
        fi
    fi

    assert_eq "test_interactivity_gates_safeguard_approval: Phase 2.6 auto-defers safeguard bugs in non-interactive mode" "found" "$safeguard_gate_found"
}

# ============================================================
# test_interactivity_gates_complex_escalation
# Non-interactive mode must log COMPLEX_ESCALATION as a ticket
# comment instead of blocking for user input.
# RED: COMPLEX_ESCALATION handling has no interactivity conditional.
# ============================================================
test_interactivity_gates_complex_escalation() {
    local escalation_gate_found="missing"

    # Extract COMPLEX_ESCALATION section and check for non-interactive logging
    local escalation_section
    escalation_section=$(python3 - "$SKILL_FILE" <<'PYEOF'
import sys, re

skill_file = sys.argv[1]
try:
    content = open(skill_file).read()
except FileNotFoundError:
    sys.exit(0)

# Find COMPLEX Escalation handling section (Step 3a or "COMPLEX Escalation Handling")
section_match = re.search(
    r'(?m)^#{1,4}\s+.*?(?:3a|COMPLEX.*Escalat).*?$(.+?)(?=^#{1,4}\s|\Z)',
    content,
    re.DOTALL
)
if section_match:
    print(section_match.group(1))
PYEOF
)

    if [[ -n "$escalation_section" ]]; then
        if echo "$escalation_section" | grep -qEi '(non.?interactive.*comment|non.?interactive.*log|log.*non.?interactive|ticket comment.*non.?interactive|non.?interactive.*COMPLEX_ESCALATION|COMPLEX_ESCALATION.*non.?interactive)'; then
            escalation_gate_found="found"
        fi
    fi

    assert_eq "test_interactivity_gates_complex_escalation: non-interactive mode logs COMPLEX_ESCALATION as ticket comment" "found" "$escalation_gate_found"
}

# ============================================================
# test_interactivity_flag_propagates_to_fix_bug
# The interactivity flag must be documented as propagated to
# /dso:fix-bug invocations so fix-bug can defer its own
# interaction points.
# RED: no flag propagation to fix-bug is documented.
# ============================================================
test_interactivity_flag_propagates_to_fix_bug() {
    local propagation_found="missing"

    # Look for interactivity flag propagation to fix-bug in any invocation context
    if grep -qEi '(interactiv.*fix.?bug|fix.?bug.*interactiv|propagat.*interactiv|interactiv.*flag.*propagat|pass.*interactiv.*fix.?bug|fix.?bug.*non.?interactiv)' "$SKILL_FILE" 2>/dev/null; then
        propagation_found="found"
    fi

    assert_eq "test_interactivity_flag_propagates_to_fix_bug: interactivity flag is propagated to fix-bug invocations" "found" "$propagation_found"
}

# ============================================================
# test_interactivity_gates_file_overlap_escalation
# Non-interactive mode must defer Phase 6 Step 1a file-overlap
# escalation (when an agent re-overwrites conflicting files) instead
# of stopping to present the conflict to the user.
# RED: Phase 6 Step 1a has no interactivity conditional.
# ============================================================
test_interactivity_gates_file_overlap_escalation() {
    local overlap_gate_found="missing"

    # Extract Phase 6 Step 1a section and check for non-interactive deferral
    local step1a_section
    step1a_section=$(python3 - "$SKILL_FILE" <<'PYEOF'
import sys, re

skill_file = sys.argv[1]
try:
    content = open(skill_file).read()
except FileNotFoundError:
    sys.exit(0)

# Find Step 1a (File Overlap Check) under Phase 6
# Match heading with "1a" and "File Overlap" or "Safety Net"
section_match = re.search(
    r'(?m)^#{1,4}\s+.*?(?:1a|File Overlap|Safety Net).*?$(.+?)(?=^#{1,4}\s|\Z)',
    content,
    re.DOTALL
)
if section_match:
    print(section_match.group(1))
PYEOF
)

    if [[ -n "$step1a_section" ]]; then
        if echo "$step1a_section" | grep -qEi '(non.?interactive.*defer|defer.*non.?interactive|non.?interactive.*escalat|escalat.*non.?interactive|non.?interactive.*overlap|overlap.*non.?interactive)'; then
            overlap_gate_found="found"
        fi
    fi

    assert_eq "test_interactivity_gates_file_overlap_escalation: Phase 6 Step 1a defers file-overlap escalation in non-interactive mode" "found" "$overlap_gate_found"
}

# ============================================================
# test_interactivity_gates_oscillation_escalation
# Non-interactive mode must defer Phase 6 Step 1b oscillation-guard
# escalation (when oscillation-check returns OSCILLATION) instead
# of stopping to present both fix approaches to the user.
# RED: Phase 6 Step 1b has no interactivity conditional.
# ============================================================
test_interactivity_gates_oscillation_escalation() {
    local oscillation_gate_found="missing"

    # Extract Phase 6 Step 1b section and check for non-interactive deferral
    local step1b_section
    step1b_section=$(python3 - "$SKILL_FILE" <<'PYEOF'
import sys, re

skill_file = sys.argv[1]
try:
    content = open(skill_file).read()
except FileNotFoundError:
    sys.exit(0)

# Find Step 1b (Critic Review / Oscillation guard) under Phase 6
section_match = re.search(
    r'(?m)^#{1,4}\s+.*?(?:1b|Critic Review|Oscillation).*?$(.+?)(?=^#{1,4}\s|\Z)',
    content,
    re.DOTALL
)
if section_match:
    print(section_match.group(1))
PYEOF
)

    if [[ -n "$step1b_section" ]]; then
        if echo "$step1b_section" | grep -qEi '(non.?interactive.*defer|defer.*non.?interactive|non.?interactive.*oscillat|oscillat.*non.?interactive|non.?interactive.*escalat.*user|escalat.*user.*non.?interactive)'; then
            oscillation_gate_found="found"
        fi
    fi

    assert_eq "test_interactivity_gates_oscillation_escalation: Phase 6 Step 1b defers oscillation-guard escalation in non-interactive mode" "found" "$oscillation_gate_found"
}

# Run all tests
test_interactivity_question_at_session_start
test_non_interactive_defers_user_input_items
test_deferred_items_get_classification_comment
test_interactivity_gates_safeguard_approval
test_interactivity_gates_complex_escalation
test_interactivity_flag_propagates_to_fix_bug
test_interactivity_gates_file_overlap_escalation
test_interactivity_gates_oscillation_escalation

print_summary
