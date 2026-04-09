#!/usr/bin/env bash
# tests/hooks/test-tdd-reviewer-standard-reference.sh
# Structural interface tests for the TDD plan reviewer's reference to the
# shared behavioral testing standard and instruction-file scoring guidance.
#
# Per Rule 5 of behavioral-testing-standard.md, we test only the structural
# boundary: required section headings and path references that form the
# navigable interface for agents reading the reviewer file. We do NOT assert
# on specific phrases or rationale wording in instruction file body text.
#
# What we test (structural boundary):
#   - behavioral-testing-standard.md is referenced by path in the reviewer
#   - An instruction-file scoring section exists (structural heading or marker)
#   - Instruction-file guidance cites Rule 5 of the shared standard
#
# What we do NOT test (content assertions prohibited by Rule 5):
#   - Specific prose wording about what the reviewer should do
#   - Rationale or explanation text in the reviewer body
#
# Usage:
#   bash tests/hooks/test-tdd-reviewer-standard-reference.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TDD_REVIEWER="$PLUGIN_ROOT/plugins/dso/skills/implementation-plan/docs/reviewers/plan/tdd.md"
BEHAVIORAL_STANDARD="$PLUGIN_ROOT/plugins/dso/skills/shared/prompts/behavioral-testing-standard.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-tdd-reviewer-standard-reference.sh ==="

# ===========================================================================
# test_behavioral_standard_referenced_by_path
# The TDD reviewer must reference behavioral-testing-standard.md by its
# file path. Structural: agents loading the reviewer discover the standard
# via this path reference. A missing path means the reviewer has no machine-
# readable pointer to the authoritative rule set.
# ===========================================================================
echo "--- test_behavioral_standard_referenced_by_path ---"
if grep -q "behavioral-testing-standard.md" "$TDD_REVIEWER" 2>/dev/null; then
    assert_eq "test_behavioral_standard_referenced_by_path: path reference present" "present" "present"
else
    assert_eq "test_behavioral_standard_referenced_by_path: path reference present" "present" "missing"
fi

# ===========================================================================
# test_referenced_standard_file_exists
# The behavioral-testing-standard.md file referenced by the reviewer must
# actually exist at the cited path. Structural: referential integrity check —
# a dangling path reference is a broken navigable interface.
# ===========================================================================
echo "--- test_referenced_standard_file_exists ---"
if [[ -f "$BEHAVIORAL_STANDARD" ]]; then
    assert_eq "test_referenced_standard_file_exists: behavioral-testing-standard.md exists" "present" "present"
else
    assert_eq "test_referenced_standard_file_exists: behavioral-testing-standard.md exists" "present" "missing"
fi

# ===========================================================================
# test_instruction_file_scoring_section_present
# The TDD reviewer must contain guidance for scoring instruction-file tasks.
# Structural: the presence of "instruction" combined with "file" or
# "non-executable" or "Rule 5" or "boundary rule" is the machine-readable
# marker that agents use to find this section. A section heading or explicit
# marker establishes the navigable interface.
# ===========================================================================
echo "--- test_instruction_file_scoring_section_present ---"
if grep -qE "instruction.file|non-executable|boundary rule|Rule 5" "$TDD_REVIEWER" 2>/dev/null; then
    assert_eq "test_instruction_file_scoring_section_present: instruction-file guidance present" "present" "present"
else
    assert_eq "test_instruction_file_scoring_section_present: instruction-file guidance present" "present" "missing"
fi

# ===========================================================================
# test_instruction_file_guidance_cites_rule5
# The instruction-file scoring guidance must cite Rule 5 of the shared
# behavioral testing standard. Structural: the citation makes the connection
# explicit — agents know which rule governs instruction-file tasks without
# reading the full reviewer narrative.
# ===========================================================================
echo "--- test_instruction_file_guidance_cites_rule5 ---"
if grep -qE "Rule 5|rule 5" "$TDD_REVIEWER" 2>/dev/null; then
    assert_eq "test_instruction_file_guidance_cites_rule5: Rule 5 cited in reviewer" "present" "present"
else
    assert_eq "test_instruction_file_guidance_cites_rule5: Rule 5 cited in reviewer" "present" "missing"
fi

print_summary
