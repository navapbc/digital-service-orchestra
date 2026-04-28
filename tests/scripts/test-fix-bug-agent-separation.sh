#!/usr/bin/env bash
# tests/scripts/test-fix-bug-agent-separation.sh
# Verifies that Step 6 of the /dso:fix-bug skill enforces agent separation:
# the fix sub-agent must receive a root_cause_report from the investigation
# sub-agent, with a HARD-GATE blocking dispatch without it, and with explicit
# exemptions documented for mechanical bugs and bot-psychologist path.
#
# RED PHASE: All tests are expected to FAIL until Step 6 in
# plugins/dso/skills/fix-bug/SKILL.md is updated to include these enforcement
# requirements.
#
# Usage:
#   bash tests/scripts/test-fix-bug-agent-separation.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

SKILL_FILE="$DSO_PLUGIN_DIR/skills/fix-bug/SKILL.md"

echo "=== test-fix-bug-agent-separation.sh ==="

# _extract_step6 <skill_file>
# Extracts the content of the "Step 6" section from SKILL.md — from the
# "### Step 6:" heading up to (but not including) the next "### Step " or
# "### Gate " heading.
_extract_step6() {
    local file="$1"
    awk '/^### Step [0-9]+: Fix Implementation/{found=1} found && /^### (Step [0-9]|Gate )/ && !/^### Step [0-9]+: Fix Implementation/{exit} found{print}' "$file"
}

# ============================================================
# test_step6_requires_root_cause_report
# Step 6 must reference a root_cause_report field — this enforces
# that the fix sub-agent receives the investigation sub-agent's
# structured report rather than an unvalidated free-form prompt.
# ============================================================
test_step6_requires_root_cause_report() {
    local step6_content
    step6_content=$(_extract_step6 "$SKILL_FILE")
    _tmp="$step6_content"
    if [[ "$_tmp" == *"root_cause_report"* ]]; then
        assert_eq "test_step6_requires_root_cause_report" "present" "present"
    else
        assert_eq "test_step6_requires_root_cause_report" "present" "missing"
    fi
}

# ============================================================
# test_step6_has_hard_gate
# Step 6 must include a HARD-GATE block or a statement that
# blocks dispatch without a root_cause_report — preventing the
# orchestrator from launching the fix sub-agent without validated
# investigation results.
# ============================================================
test_step6_has_hard_gate() {
    local step6_content
    step6_content=$(_extract_step6 "$SKILL_FILE")
    _tmp="$step6_content"
    if [[ "$_tmp" =~ HARD-GATE|blocks.*root_cause_report ]]; then
        assert_eq "test_step6_has_hard_gate" "present" "present"
    else
        assert_eq "test_step6_has_hard_gate" "present" "missing"
    fi
}

# ============================================================
# test_mechanical_exempt
# Step 6 must document that mechanical bugs are exempt from the
# root_cause_report requirement — mechanical fixes (import errors,
# lint violations, config syntax) bypass the investigation sub-agent
# entirely, so the gate must not block them.
# ============================================================
test_mechanical_exempt() {
    local step6_content
    step6_content=$(_extract_step6 "$SKILL_FILE")
    _tmp="$step6_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ mechanical.*exempt|exempt.*mechanical ]]; then
        shopt -u nocasematch
        assert_eq "test_mechanical_exempt" "present" "present"
    else
        shopt -u nocasematch
        assert_eq "test_mechanical_exempt" "present" "missing"
    fi
}

# ============================================================
# test_bot_psychologist_exempt
# Step 6 must document that the bot-psychologist path is exempt
# from the root_cause_report gate — the bot-psychologist agent
# produces a different structured output and must not be blocked
# by a requirement designed for the standard investigation path.
# ============================================================
test_bot_psychologist_exempt() {
    local step6_content
    step6_content=$(_extract_step6 "$SKILL_FILE")
    _tmp="$step6_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ bot.psychologist.*exempt|exempt.*bot.psychologist ]]; then
        shopt -u nocasematch
        assert_eq "test_bot_psychologist_exempt" "present" "present"
    else
        shopt -u nocasematch
        assert_eq "test_bot_psychologist_exempt" "present" "missing"
    fi
}

# --- Run all tests ---
echo "--- test_step6_requires_root_cause_report ---"
test_step6_requires_root_cause_report

echo "--- test_step6_has_hard_gate ---"
test_step6_has_hard_gate

echo "--- test_mechanical_exempt ---"
test_mechanical_exempt

echo "--- test_bot_psychologist_exempt ---"
test_bot_psychologist_exempt

print_summary
