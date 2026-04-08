#!/usr/bin/env bash
# tests/hooks/test-implementation-plan-standard-reference.sh
# Structural interface tests for the behavioral testing standard reference in
# implementation-plan/SKILL.md.
#
# This test file verifies that the "Behavioral Test Requirement" section in
# implementation-plan/SKILL.md has been replaced with a reference to the shared
# behavioral testing standard and that Given/When/Then framing has been adopted.
#
# Per Rule 5 of the behavioral-testing-standard.md, tests for non-executable
# instruction files must test ONLY structural boundaries (section headings,
# required references, schema compliance) — not content or wording assertions.
#
# What we test (structural boundary):
#   - The shared standard is referenced by path (referential integrity)
#   - Given/When/Then framing appears in the test approach guidance
#   - The "Behavioral Test Requirement" section no longer contains inline rule definitions
#   - Preserved planning-specific sections (Unit Test Exemption Criteria,
#     Integration Test Task Rule) are still present
#
# What we do NOT test (content assertions prohibited by Rule 5):
#   - Specific wording of the description text
#   - Exact sentence structure of references
#
# Usage:
#   bash tests/hooks/test-implementation-plan-standard-reference.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-standard-reference.sh ==="

# ===========================================================================
# test_shared_standard_referenced_by_path
# Given: implementation-plan/SKILL.md has been updated
# When: we look for a reference to the shared behavioral testing standard
# Then: the file contains the path "behavioral-testing-standard.md"
#
# Structural: the path is a referential integrity contract — agents must know
# where to load the shared standard from.
# ===========================================================================
echo "--- test_shared_standard_referenced_by_path ---"
if grep -q "behavioral-testing-standard.md" "$SKILL_FILE" 2>/dev/null; then
    assert_eq "test_shared_standard_referenced_by_path: shared standard path present" "present" "present"
else
    assert_eq "test_shared_standard_referenced_by_path: shared standard path present" "present" "missing"
fi

# ===========================================================================
# test_given_when_then_framing_present
# Given: implementation-plan/SKILL.md uses the shared standard's Rule 2 format
# When: we check for Given/When/Then framing in the test approach guidance
# Then: the file contains "Given/When/Then" or the equivalent pattern
#
# Structural: Given/When/Then is the section-level framing contract declared
# by the shared standard Rule 2 — its presence signals agents to apply it.
# ===========================================================================
echo "--- test_given_when_then_framing_present ---"
if grep -qE "Given.*When.*Then|Given/When/Then" "$SKILL_FILE" 2>/dev/null; then
    assert_eq "test_given_when_then_framing_present: Given/When/Then framing present" "present" "present"
else
    assert_eq "test_given_when_then_framing_present: Given/When/Then framing present" "present" "missing"
fi

# ===========================================================================
# test_inline_rule_definitions_removed
# Given: the "Behavioral Test Requirement" section previously contained
#        inline rule definitions with the phrase "valid RED test must"
# When: we check whether those inline definitions still exist
# Then: the inline rule definition phrase should no longer appear in context
#       immediately after the "Behavioral Test Requirement" heading
#
# Structural: the structural contract is the section heading interface;
# inline duplication of the shared standard's rules is the anti-pattern
# being removed. We check that the old inline content ("valid RED test must")
# does not appear within 5 lines of the heading.
# ===========================================================================
echo "--- test_inline_rule_definitions_removed ---"
_inline_check=$(grep -A5 "#### Behavioral Test Requirement" "$SKILL_FILE" 2>/dev/null | grep "valid RED test must" || true)
if [[ -z "$_inline_check" ]]; then
    assert_eq "test_inline_rule_definitions_removed: inline rule definitions removed" "removed" "removed"
else
    assert_eq "test_inline_rule_definitions_removed: inline rule definitions removed" "removed" "still_present"
fi

# ===========================================================================
# test_unit_test_exemption_criteria_preserved
# Given: the Unit Test Exemption Criteria section contains planning-specific rules
# When: we check whether the section heading is still present
# Then: "Unit Test Exemption Criteria" appears in the skill file
#
# Structural: section heading is the navigable interface for agents and reviewers.
# ===========================================================================
echo "--- test_unit_test_exemption_criteria_preserved ---"
if grep -q "Unit Test Exemption Criteria" "$SKILL_FILE" 2>/dev/null; then
    assert_eq "test_unit_test_exemption_criteria_preserved: section heading present" "present" "present"
else
    assert_eq "test_unit_test_exemption_criteria_preserved: section heading present" "present" "missing"
fi

# ===========================================================================
# test_integration_test_task_rule_preserved
# Given: the Integration Test Task Rule section contains planning-specific rules
# When: we check whether the section heading is still present
# Then: "Integration Test Task Rule" appears in the skill file
#
# Structural: section heading is the navigable interface for agents and reviewers.
# ===========================================================================
echo "--- test_integration_test_task_rule_preserved ---"
if grep -q "Integration Test Task Rule" "$SKILL_FILE" 2>/dev/null; then
    assert_eq "test_integration_test_task_rule_preserved: section heading present" "present" "present"
else
    assert_eq "test_integration_test_task_rule_preserved: section heading present" "present" "missing"
fi

print_summary
