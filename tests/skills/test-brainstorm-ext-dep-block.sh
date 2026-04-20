#!/usr/bin/env bash
# Structural boundary test for brainstorm SKILL.md Shape Heuristic sub-step.
# Rule 5 compliant: tests structural tokens that the SKILL.md must contain —
# specific section names and file references are structural identifiers.
#
# RED marker: [test_skill_md_has_shape_heuristic_section]
# GREEN sibling: task b796-fc52 (adds the Shape Heuristic sub-step to SKILL.md)
#
# Asserts:
#   1. SKILL.md contains 'Shape Heuristic Scan' section heading
#   2. SKILL.md references classify-sc-shape.sh script
#   3. SKILL.md references external-dependencies-block.md contract doc
#   4. SKILL.md references planning.external_dependency_block_enabled flag or
#      is_external_dep_block_enabled or planning-config.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Test 1: Shape Heuristic Scan section exists (RED marker boundary)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_skill_md_has_shape_heuristic_section() {
    grep -q 'Shape Heuristic Scan' "$SKILL_MD" || { echo "FAIL: ${FUNCNAME[0]}"; return 1; }
    echo "PASS: ${FUNCNAME[0]}"
}

# ---------------------------------------------------------------------------
# Test 2: SKILL.md references the classify-sc-shape.sh script
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_skill_md_references_classify_script() {
    grep -q 'classify-sc-shape.sh' "$SKILL_MD" || { echo "FAIL: ${FUNCNAME[0]}"; return 1; }
    echo "PASS: ${FUNCNAME[0]}"
}

# ---------------------------------------------------------------------------
# Test 3: SKILL.md references the external-dependencies-block.md contract doc
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_skill_md_references_contract_doc() {
    grep -q 'external-dependencies-block.md' "$SKILL_MD" || { echo "FAIL: ${FUNCNAME[0]}"; return 1; }
    echo "PASS: ${FUNCNAME[0]}"
}

# ---------------------------------------------------------------------------
# Test 4: SKILL.md references the planning flag or config helper
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
test_skill_md_references_planning_flag() {
    grep -qE 'planning\.external_dependency_block_enabled|is_external_dep_block_enabled|planning-config\.sh' "$SKILL_MD" || { echo "FAIL: ${FUNCNAME[0]}"; return 1; }
    echo "PASS: ${FUNCNAME[0]}"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
tests=(
    test_skill_md_has_shape_heuristic_section
    test_skill_md_references_classify_script
    test_skill_md_references_contract_doc
    test_skill_md_references_planning_flag
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
