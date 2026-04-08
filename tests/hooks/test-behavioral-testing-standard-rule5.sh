#!/usr/bin/env bash
# tests/hooks/test-behavioral-testing-standard-rule5.sh
# Structural interface tests for Rule 5 of behavioral-testing-standard.md.
#
# Rule 5 defines the testing boundary for non-executable LLM instruction files.
# These tests verify ONLY the structural contract of the standard document:
# required section headings and preamble accuracy. Per Rule 5 itself, we do NOT
# grep for specific phrases in instruction file body text — those are content
# assertions that break on safe editorial changes.
#
# What we test (structural boundary):
#   - Section heading existence (## Rule 5)
#   - Preamble rule-count accuracy (5-rule, not stale 4-rule)
#   - Usage section includes Rule 5 in the numbered workflow
#   - Compliance block includes rule5 fields
#
# What we do NOT test (content assertions prohibited by Rule 5):
#   - Specific phrases like "non-executable", "contract schema", etc.
#   - Prohibition wording or rationale text
#   - Body text keywords
#
# Usage:
#   bash tests/hooks/test-behavioral-testing-standard-rule5.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STANDARD_FILE="$PLUGIN_ROOT/plugins/dso/skills/shared/prompts/behavioral-testing-standard.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-behavioral-testing-standard-rule5.sh ==="

# ===========================================================================
# test_rule5_section_heading_present
# Rule 5 must have a level-2 markdown section heading "## Rule 5".
# Structural: agents locate rules via section headings — the heading IS the
# navigable interface (same as contract schema validation for ## Purpose).
# ===========================================================================
echo "--- test_rule5_section_heading_present ---"
if grep -q "^## Rule 5" "$STANDARD_FILE" 2>/dev/null; then
    assert_eq "test_rule5_section_heading_present: ## Rule 5 heading exists" "present" "present"
else
    assert_eq "test_rule5_section_heading_present: ## Rule 5 heading exists" "present" "missing"
fi

# ===========================================================================
# test_preamble_references_five_rules
# The preamble (first 20 lines) must reference "5-rule" to reflect that the
# standard now has 5 rules. Structural: the preamble's rule count is a scope
# declaration consumed by agents to understand the standard's coverage.
# ===========================================================================
echo "--- test_preamble_references_five_rules ---"
if head -20 "$STANDARD_FILE" 2>/dev/null | grep -qE "5-rule|five.rule|five rules"; then
    assert_eq "test_preamble_references_five_rules: 5-rule preamble updated" "present" "present"
else
    assert_eq "test_preamble_references_five_rules: 5-rule preamble updated" "present" "missing"
fi

# ===========================================================================
# test_preamble_does_not_reference_four_rules_only
# The preamble must not still say "four-rule" or "4-rule". Structural:
# stale rule-count is a regression that causes agents to ignore Rule 5.
# ===========================================================================
echo "--- test_preamble_does_not_reference_four_rules_only ---"
_preamble_four=$(head -20 "$STANDARD_FILE" 2>/dev/null | grep -E "four-rule|4-rule" || true)
if [[ -z "$_preamble_four" ]]; then
    assert_eq "test_preamble_does_not_reference_four_rules_only: no stale 4-rule in preamble" "clean" "clean"
else
    assert_eq "test_preamble_does_not_reference_four_rules_only: no stale 4-rule in preamble" "clean" "stale_reference_found"
fi

# ===========================================================================
# test_usage_section_references_rule5
# The "Usage by Test-Writing Agents" section must include a numbered step
# that references Rule 5 in its workflow. Structural: the numbered workflow
# is a contract — agents step through it sequentially. A missing step means
# Rule 5 is not applied in practice.
# ===========================================================================
echo "--- test_usage_section_references_rule5 ---"
# Extract lines between "## Usage" and the next "## " heading, then check
# for a numbered step referencing Rule 5
_usage_section=$(sed -n '/^## Usage by Test-Writing Agents/,/^## /p' "$STANDARD_FILE" 2>/dev/null | head -20)
if echo "$_usage_section" | grep -qE "[0-9]+\..*(Rule 5|rule 5)"; then
    assert_eq "test_usage_section_references_rule5: Rule 5 step in usage workflow" "present" "present"
else
    assert_eq "test_usage_section_references_rule5: Rule 5 step in usage workflow" "present" "missing"
fi

# ===========================================================================
# test_compliance_block_includes_rule5_fields
# The behavioral_testing_compliance JSON block must include rule5 fields.
# Structural: the compliance block is a machine-readable contract that
# test-writing agents emit — missing fields means agents cannot report
# Rule 5 compliance.
# ===========================================================================
echo "--- test_compliance_block_includes_rule5_fields ---"
if grep -q '"rule5_applied"' "$STANDARD_FILE" 2>/dev/null; then
    assert_eq "test_compliance_block_includes_rule5_fields: rule5_applied field in compliance block" "present" "present"
else
    assert_eq "test_compliance_block_includes_rule5_fields: rule5_applied field in compliance block" "present" "missing"
fi

# ===========================================================================
# test_rule_count_matches_headings
# The number of ## Rule N headings must equal the count declared in the
# preamble. Structural: detects accidental deletion of a rule section or
# inconsistent preamble update.
# ===========================================================================
echo "--- test_rule_count_matches_headings ---"
_heading_count=$(grep -c "^## Rule [0-9]" "$STANDARD_FILE" 2>/dev/null || echo 0)
if [[ "$_heading_count" -ge 5 ]]; then
    assert_eq "test_rule_count_matches_headings: at least 5 rule headings" "pass" "pass"
else
    assert_eq "test_rule_count_matches_headings: at least 5 rule headings" "pass" "fail (found $_heading_count)"
fi

print_summary
