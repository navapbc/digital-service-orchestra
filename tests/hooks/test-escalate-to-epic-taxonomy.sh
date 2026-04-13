#!/usr/bin/env bash
# tests/hooks/test-escalate-to-epic-taxonomy.sh
# Structural contract tests for escalate_to_epic taxonomy support in red-team
# and blue-team agent output schemas.
#
# These tests verify the output contract (JSON schema enum values and taxonomy
# category headings) of the red-team-reviewer and blue-team-filter agents.
# Per Rule 5 of behavioral-testing-standard.md, we test the structural boundary
# of these non-executable instruction files: the machine-readable output format
# fields that the orchestrator parses, not prose body text.
#
# What we test (structural contract):
#   - red-team-reviewer.md Field Definitions table includes "escalate_to_epic"
#     as a valid `type` enum value
#   - red-team-reviewer.md has a "Residual References" taxonomy category heading
#   - red-team-reviewer.md taxonomy_category enum includes "residual_references"
#   - blue-team-filter.md output schema Field Definitions reference "escalate_to_epic"
#
# What we do NOT test:
#   - Prose explanation text about what escalate_to_epic means
#   - Implementation details of how the agents process findings
#   - Body text wording beyond the schema contract fields
#
# Usage:
#   bash tests/hooks/test-escalate-to-epic-taxonomy.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED_TEAM_FILE="$REPO_ROOT/plugins/dso/agents/red-team-reviewer.md"
BLUE_TEAM_FILE="$REPO_ROOT/plugins/dso/agents/blue-team-filter.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-escalate-to-epic-taxonomy.sh ==="

# ===========================================================================
# test_red_team_has_residual_references_category
# The red-team-reviewer.md must define "Residual References" as a named
# taxonomy category section heading. Category headings are the structural
# interface that agents use to enumerate and iterate analysis areas —
# they are navigable section markers, not body prose.
# ===========================================================================
echo "--- test_red_team_has_residual_references_category ---"
if grep -q "Residual References" "$RED_TEAM_FILE" 2>/dev/null; then
    assert_eq "test_red_team_has_residual_references_category: Residual References category present" "present" "present"
else
    assert_eq "test_red_team_has_residual_references_category: Residual References category present" "present" "missing"
fi

# ===========================================================================
# test_red_team_type_enum_includes_escalate_to_epic
# The red-team-reviewer.md Field Definitions table lists valid values for the
# `type` field. This is the output contract enum — the orchestrator dispatches
# on these exact string values. "escalate_to_epic" must appear in that table.
# ===========================================================================
echo "--- test_red_team_type_enum_includes_escalate_to_epic ---"
if grep -q "escalate_to_epic" "$RED_TEAM_FILE" 2>/dev/null; then
    assert_eq "test_red_team_type_enum_includes_escalate_to_epic: escalate_to_epic type in schema" "present" "present"
else
    assert_eq "test_red_team_type_enum_includes_escalate_to_epic: escalate_to_epic type in schema" "present" "missing"
fi

# ===========================================================================
# test_red_team_taxonomy_enum_includes_residual_references
# The red-team-reviewer.md Field Definitions table lists valid values for the
# `taxonomy_category` field. "residual_references" must appear as an enum
# value so orchestrators can route findings of that category correctly.
# ===========================================================================
echo "--- test_red_team_taxonomy_enum_includes_residual_references ---"
if grep -q "residual_references" "$RED_TEAM_FILE" 2>/dev/null; then
    assert_eq "test_red_team_taxonomy_enum_includes_residual_references: residual_references taxonomy enum value present" "present" "present"
else
    assert_eq "test_red_team_taxonomy_enum_includes_residual_references: residual_references taxonomy enum value present" "present" "missing"
fi

# ===========================================================================
# test_blue_team_recognizes_escalate_to_epic
# The blue-team-filter.md output schema passes through all red team finding
# fields including `type`. The schema field definitions must reference
# "escalate_to_epic" so the blue team correctly handles this finding type
# rather than silently dropping or misrouting it.
# ===========================================================================
echo "--- test_blue_team_recognizes_escalate_to_epic ---"
if grep -q "escalate_to_epic" "$BLUE_TEAM_FILE" 2>/dev/null; then
    assert_eq "test_blue_team_recognizes_escalate_to_epic: escalate_to_epic recognized in blue team schema" "present" "present"
else
    assert_eq "test_blue_team_recognizes_escalate_to_epic: escalate_to_epic recognized in blue team schema" "present" "missing"
fi

print_summary
