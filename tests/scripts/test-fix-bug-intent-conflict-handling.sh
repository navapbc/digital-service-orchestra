#!/usr/bin/env bash
# tests/scripts/test-fix-bug-intent-conflict-handling.sh
# Structural assertions: fix-bug/SKILL.md must contain INTENT_CONFLICT handling
# in Step 1.5 (Gate 1a) and Step 1.7 (Gate 1b skip condition).
#
# RED PHASE: All tests are expected to FAIL until plugins/dso/skills/fix-bug/SKILL.md
# is updated to include INTENT_CONFLICT as a 4th terminal outcome in Step 1.5,
# add it to the Gate 1b skip condition in Step 1.7, and add INTERACTIVITY_DEFERRED
# handling for non-interactive mode.
#
# Usage: bash tests/scripts/test-fix-bug-intent-conflict-handling.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"

: "${PASS:=0}"
: "${FAIL:=0}"

echo "=== test-fix-bug-intent-conflict-handling.sh ==="
echo ""

# _extract_step15 <skill_file>
# Extracts the content of the "Step 1.5" section from SKILL.md — from the
# "### Step 1.5:" heading up to (but not including) the next "### Step " heading.
_extract_step15() {
    local file="$1"
    awk '/^### Step 1\.5:/{found=1} found && /^### Step [0-9]/ && !/^### Step 1\.5:/{exit} found{print}' "$file"
}

# _extract_step17 <skill_file>
# Extracts the content of the "Step 1.7" section from SKILL.md — from the
# "### Step 1.7:" heading up to (but not including) the next "### Step " heading.
_extract_step17() {
    local file="$1"
    awk '/^### Step 1\.7:/{found=1} found && /^### Step [0-9]/ && !/^### Step 1\.7:/{exit} found{print}' "$file"
}

# ============================================================
# test_intent_conflict_outcome_exists
# Step 1.5 must mention 'intent-conflict' as a Gate 1a outcome.
# This is the primary RED marker — until SKILL.md is updated,
# this test FAILS to confirm the implementation is missing.
# ============================================================
echo "--- test_intent_conflict_outcome_exists ---"
test_intent_conflict_outcome_exists() {
    local step15_content
    step15_content=$(_extract_step15 "$SKILL_FILE")
    if grep -q 'intent-conflict' <<< "$step15_content"; then
        echo "PASS: test_intent_conflict_outcome_exists"
        (( PASS++ ))
    else
        echo "FAIL: test_intent_conflict_outcome_exists — Step 1.5 does not mention 'intent-conflict'" >&2
        (( FAIL++ ))
    fi
}
test_intent_conflict_outcome_exists

# ============================================================
# test_three_resolution_options
# Near INTENT_CONFLICT in SKILL.md, there must be all three
# resolution options: 'confirm ticket correct', 'confirm current
# behavior', and 'revise ticket description'.
# ============================================================
echo ""
echo "--- test_three_resolution_options ---"
test_three_resolution_options() {
    local step15_content
    step15_content=$(_extract_step15 "$SKILL_FILE")
    local missing=0
    for option in "confirm ticket correct" "confirm current behavior" "revise ticket description"; do
        if ! grep -qi "$option" <<< "$step15_content"; then
            echo "FAIL: test_three_resolution_options — missing option: '$option'" >&2
            (( FAIL++ ))
            missing=1
        fi
    done
    if [[ "$missing" -eq 0 ]]; then
        echo "PASS: test_three_resolution_options"
        (( PASS++ ))
    fi
}
test_three_resolution_options

# ============================================================
# test_gate_1a_result_intent_conflict
# Step 1.5 must set GATE_1A_RESULT to 'intent-conflict' when
# the outcome is triggered. The pattern checks for the assignment
# in either direction.
# ============================================================
echo ""
echo "--- test_gate_1a_result_intent_conflict ---"
test_gate_1a_result_intent_conflict() {
    local step15_content
    step15_content=$(_extract_step15 "$SKILL_FILE")
    if grep -qE 'GATE_1A_RESULT.*intent-conflict|intent-conflict.*GATE_1A_RESULT' <<< "$step15_content"; then
        echo "PASS: test_gate_1a_result_intent_conflict"
        (( PASS++ ))
    else
        echo "FAIL: test_gate_1a_result_intent_conflict — GATE_1A_RESULT='intent-conflict' assignment not found in Step 1.5" >&2
        (( FAIL++ ))
    fi
}
test_gate_1a_result_intent_conflict

# ============================================================
# test_step_1_7_skips_intent_conflict
# Step 1.7 must include 'intent-conflict' in its skip condition
# so Gate 1b is bypassed when the outcome is intent-conflict
# (just like intent-aligned and intent-contradicting).
# ============================================================
echo ""
echo "--- test_step_1_7_skips_intent_conflict ---"
test_step_1_7_skips_intent_conflict() {
    local step17_content
    step17_content=$(_extract_step17 "$SKILL_FILE")
    if grep -q 'intent-conflict' <<< "$step17_content"; then
        echo "PASS: test_step_1_7_skips_intent_conflict"
        (( PASS++ ))
    else
        echo "FAIL: test_step_1_7_skips_intent_conflict — Step 1.7 skip condition does not include 'intent-conflict'" >&2
        (( FAIL++ ))
    fi
}
test_step_1_7_skips_intent_conflict

# ============================================================
# test_non_interactive_deferred
# Near 'intent-conflict' in SKILL.md there must be an
# INTERACTIVITY_DEFERRED handling clause for non-interactive mode.
# ============================================================
echo ""
echo "--- test_non_interactive_deferred ---"
test_non_interactive_deferred() {
    # Both 'intent-conflict' and 'INTERACTIVITY_DEFERRED' must appear
    # in the Step 1.5 section — grep directly against the file to avoid
    # bash variable piping limitations with large files.
    local step15_content
    step15_content=$(_extract_step15 "$SKILL_FILE")

    # Write step15 to a temp file for reliable large-content grep
    local tmp_step15
    tmp_step15=$(mktemp)
    printf "%s" "$step15_content" > "$tmp_step15"

    local has_intent_conflict=0
    local step15_has_deferred=0
    grep -q 'intent-conflict' "$tmp_step15" && has_intent_conflict=1 || true
    grep -q 'INTERACTIVITY_DEFERRED' "$tmp_step15" && step15_has_deferred=1 || true
    rm -f "$tmp_step15"

    if [[ "$has_intent_conflict" -eq 1 && "$step15_has_deferred" -eq 1 ]]; then
        echo "PASS: test_non_interactive_deferred"
        (( PASS++ ))
    else
        echo "FAIL: test_non_interactive_deferred — INTERACTIVITY_DEFERRED not found near intent-conflict in Step 1.5" >&2
        (( FAIL++ ))
    fi
}
test_non_interactive_deferred

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
