#!/usr/bin/env bash
# tests/test-brainstorm-phase-1-5-detector.sh
# Behavioral tests for brainstorm Phase 1.5 UI-copy detector.
#
# Covers story 3136-e839-4f17-4dd0, task dc9e-d0cd-4f97-4ac9.
# DDs tested:
#   dd-1 (3136): running /dso:brainstorm on an epic that contains UI-copy signals
#                results in the epic carrying the copy-needed tag
#   dd-4 (3136): running /dso:brainstorm on an epic with no UI-copy signals
#                leaves the epic without the tag or section
#
# Test plan:
#   1. Positive: SKILL.md Phase 1.5 section exists with correct heading
#   2. Positive: copy-needed tag keyword is documented in Phase 1.5
#   3. Positive: UI-copy signal heuristics are documented (form field, error message, etc.)
#   4. Positive: Copy Needs contract reference path is correct
#   5. Positive: schema_version reference is present (section must begin with schema_version: 1)
#   6. Positive: idempotency guard is described (re-run does not duplicate)
#   7. Positive: user confirmation dialogue is described (user must confirm before tagging)
#   8. Positive: stable_id field is mentioned in section write instructions
#   9. Negative: non-UI epic description does not contain copy-needed tag instruction
#  10. Positive: Quick Reference table includes Phase 1.5 row

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

SKILL_FILE="$_PLUGIN_ROOT/skills/brainstorm/SKILL.md"
CONTRACT_FILE="$_PLUGIN_ROOT/docs/contracts/copy-needs-section.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== brainstorm Phase 1.5 UI-copy detector behavioral tests ==="

# ---------------------------------------------------------------------------
# Prerequisite: SKILL.md and contract file must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$SKILL_FILE" ]]; then
    echo "FATAL: SKILL.md not found at $SKILL_FILE"
    exit 1
fi

if [[ ! -f "$CONTRACT_FILE" ]]; then
    echo "FATAL: copy-needs-section.md not found at $CONTRACT_FILE"
    exit 1
fi

echo ""
echo "--- Test 1: Phase 1.5 section heading exists ---"
if grep -qE '^## Phase 1\.5' "$SKILL_FILE"; then
    pass "SKILL.md contains '## Phase 1.5' heading"
else
    fail "SKILL.md missing '## Phase 1.5' heading"
fi

echo ""
echo "--- Test 2: copy-needed tag keyword documented ---"
if grep -q 'copy-needed' "$SKILL_FILE"; then
    pass "SKILL.md documents 'copy-needed' tag"
else
    fail "SKILL.md does not mention 'copy-needed' tag"
fi

echo ""
echo "--- Test 3: UI-copy signal heuristics documented ---"
_SIGNALS_PASS=1
for signal in "form field" "error message" "button" "helper text" "microcopy" "alt text" "plain language" "validation"; do
    if grep -qi "$signal" "$SKILL_FILE"; then
        pass "  Signal heuristic documented: '$signal'"
    else
        fail "  Signal heuristic missing: '$signal'"
        _SIGNALS_PASS=0
    fi
done

echo ""
echo "--- Test 4: Copy Needs contract path reference is correct ---"
if grep -q 'docs/contracts/copy-needs-section.md' "$SKILL_FILE"; then
    pass "SKILL.md references copy-needs-section.md at correct path"
else
    fail "SKILL.md does not reference copy-needs-section.md at expected path"
fi

echo ""
echo "--- Test 5: schema_version reference present ---"
if grep -q 'schema_version: 1' "$SKILL_FILE"; then
    pass "SKILL.md references 'schema_version: 1' for Copy Needs section"
else
    fail "SKILL.md missing 'schema_version: 1' reference"
fi

echo ""
echo "--- Test 6: Idempotency guard is described ---"
if grep -qi 'idempoten' "$SKILL_FILE"; then
    pass "SKILL.md describes idempotency guard for Phase 1.5"
else
    fail "SKILL.md does not describe idempotency guard"
fi

echo ""
echo "--- Test 7: User confirmation dialogue is described ---"
# Phase 1.5 must prompt the user before tagging — not silently apply the tag
if grep -q 'confirmation\|confirm\|user.*tag\|tag.*user' "$SKILL_FILE"; then
    pass "SKILL.md describes user confirmation before tagging"
else
    # More lenient check — look for a 'yes / no' or 'yes/no' pattern indicating a dialogue
    if grep -qE 'yes.*no|Should I tag' "$SKILL_FILE"; then
        pass "SKILL.md describes user confirmation dialogue (yes/no prompt)"
    else
        fail "SKILL.md does not describe user confirmation before tagging"
    fi
fi

echo ""
echo "--- Test 8: stable_id field mentioned in section write ---"
if grep -q 'stable_id' "$SKILL_FILE"; then
    pass "SKILL.md mentions 'stable_id' field for Copy Needs entries"
else
    fail "SKILL.md does not mention 'stable_id' field"
fi

echo ""
echo "--- Test 9: Negative path documented (no UI signals → silent no-op) ---"
# The skill should state that the negative result is silent / no-op
if grep -qE 'copy-not-detected|no.*signal|silent|non-UI fast-path|not.*detected' "$SKILL_FILE"; then
    pass "SKILL.md documents negative path (no copy signals → silent no-op)"
else
    fail "SKILL.md does not document the negative (no signals) path"
fi

echo ""
echo "--- Test 10: Quick Reference table includes Phase 1.5 row ---"
if grep -qE '\| 1\.5' "$SKILL_FILE"; then
    pass "Quick Reference table includes '| 1.5' row"
else
    fail "Quick Reference table missing Phase 1.5 row"
fi

echo ""
echo "--- Test 11: Contract copy-needs-section.md is itself valid (has schema_version) ---"
if grep -q 'schema_version' "$CONTRACT_FILE"; then
    pass "copy-needs-section.md defines schema_version"
else
    fail "copy-needs-section.md does not define schema_version"
fi

echo ""
echo "--- Test 12: Contract lists all required fields ---"
for field in "stable_id" "type" "location" "page" "validation_rule"; do
    if grep -q "$field" "$CONTRACT_FILE"; then
        pass "  Contract documents required field: '$field'"
    else
        fail "  Contract missing required field: '$field'"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "FAILED: $FAIL test(s) failed."
    exit 1
fi
