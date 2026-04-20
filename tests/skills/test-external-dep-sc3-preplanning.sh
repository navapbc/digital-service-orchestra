#!/usr/bin/env bash
# Structural boundary test for preplanning SKILL.md External Dependencies SC3 features.
# Rule 5 compliant: tests structural tokens that the SKILL.md must contain —
# section headings and behavioral boundary tokens are structural identifiers,
# not content assertions.
#
# Asserts:
#   1. SKILL.md contains the Phase 1.5 External Dependencies block reader section
#   2. SKILL.md contains the Refusal Gate section with diagnostic when block is
#      missing or incomplete
#   3. SKILL.md contains the handling=user_manual → manual:awaiting_user tag assignment
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Test 1: Phase 1.5 External Dependencies Block Reading section exists
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_skill_md_has_ext_dep_block_reader_section() {
    grep -q 'Phase 1.5: External Dependencies Block Reading' "$SKILL_MD" || { echo "FAIL: ${FUNCNAME[0]}"; return 1; }
    echo "PASS: ${FUNCNAME[0]}"
}

# ---------------------------------------------------------------------------
# Test 2: Refusal Gate section with diagnostic for missing/incomplete block exists
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_skill_md_has_refusal_gate_section() {
    grep -q 'Refusal Gate: External Dependencies Block Check' "$SKILL_MD" || { echo "FAIL: ${FUNCNAME[0]}"; return 1; }
    echo "PASS: ${FUNCNAME[0]}"
}

# ---------------------------------------------------------------------------
# Test 3: handling=user_manual entries get tagged manual:awaiting_user
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_skill_md_has_user_manual_awaiting_tag() {
    grep -q 'manual:awaiting_user' "$SKILL_MD" || { echo "FAIL: ${FUNCNAME[0]}"; return 1; }
    echo "PASS: ${FUNCNAME[0]}"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
tests=(
    test_skill_md_has_ext_dep_block_reader_section
    test_skill_md_has_refusal_gate_section
    test_skill_md_has_user_manual_awaiting_tag
)

for t in "${tests[@]}"; do
    if "$t"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
