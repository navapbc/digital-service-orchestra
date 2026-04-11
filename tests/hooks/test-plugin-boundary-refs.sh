#!/usr/bin/env bash
# tests/hooks/test-plugin-boundary-refs.sh
# Structural boundary tests for plugin boundary enforcement (story ec03-5076).
#
# Tests verify ONLY structural boundary contracts per Rule 5 of the behavioral
# testing standard: referential integrity, contract schema validation, and
# deployment prerequisites. They do NOT test LLM behavioral correctness.
#
# What we test (Rule 5 acceptable categories):
#   - Contract schema validation: CLAUDE.md contains plugin boundary rule
#     with required structural elements (positive enumeration + NEVER-statement)
#   - Referential integrity: cascade-replan-protocol.md exists at its canonical path
#   - Referential integrity: no dev-artifact paths in agent/skill files (grep gate DD7)
#
# Usage:
#   bash tests/hooks/test-plugin-boundary-refs.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

CLAUDE_MD="$PLUGIN_ROOT/CLAUDE.md"
CASCADE_REPLAN_SKILL_PATH="$PLUGIN_ROOT/plugins/dso/skills/sprint/docs/cascade-replan-protocol.md"
CASCADE_REPLAN_OLD_PATH="$PLUGIN_ROOT/plugins/dso/docs/designs/cascade-replan-protocol.md"

echo "=== test-plugin-boundary-refs.sh ==="

# ===========================================================================
# test_claude_md_has_plugin_boundary_rule
#
# Given: CLAUDE.md exists at repo root
# When:  grep for plugin boundary rule heading and required structural elements
# Then:  Rule heading exists in Never Do These section;
#        positive enumeration directories listed (docs/designs/, docs/findings/,
#        docs/archive/, tests/);
#        NEVER-statement prohibiting plugins/dso/ for dev-team artifacts is present
#
# Rule 5 category: Contract schema validation — the structural markers
# (heading + enumeration + NEVER keyword) are the machine-navigable interface
# that enforces the plugin boundary policy. These are structural boundary markers,
# not content assertions about wording.
# ===========================================================================
echo "--- test_claude_md_has_plugin_boundary_rule ---"

# Check CLAUDE.md exists
if [[ -f "$CLAUDE_MD" ]]; then
    assert_eq "test_claude_md_has_plugin_boundary_rule: CLAUDE.md exists" "present" "present"
else
    assert_eq "test_claude_md_has_plugin_boundary_rule: CLAUDE.md exists" "present" "missing"
fi

# Check positive enumeration: docs/designs/ must appear in the plugin boundary rule context
# This is a structural marker — the boundary list is the interface contract
if grep -q "docs/designs/" "$CLAUDE_MD" 2>/dev/null && \
   grep -q "docs/findings/" "$CLAUDE_MD" 2>/dev/null && \
   grep -q "docs/archive/" "$CLAUDE_MD" 2>/dev/null; then
    assert_eq "test_claude_md_has_plugin_boundary_rule: positive enumeration present" "present" "present"
else
    assert_eq "test_claude_md_has_plugin_boundary_rule: positive enumeration present" "present" "missing"
fi

# Check NEVER-statement: CLAUDE.md must contain a NEVER statement prohibiting
# plugins/dso/ for dev-team artifacts in the Never Do These section
# This is a structural contract: the NEVER keyword + plugins/dso/ path is the policy boundary marker
if grep -q "plugins/dso/" "$CLAUDE_MD" 2>/dev/null && \
   grep -iq "never.*dev-team artifacts\|never.*plugins/dso\|do not.*store.*plugins/dso" "$CLAUDE_MD" 2>/dev/null; then
    assert_eq "test_claude_md_has_plugin_boundary_rule: NEVER-statement present" "present" "present"
else
    assert_eq "test_claude_md_has_plugin_boundary_rule: NEVER-statement present" "present" "missing"
fi

# ===========================================================================
# test_cascade_replan_at_skill_path
#
# Given: plugins/dso/skills/sprint/docs/ is the canonical location for sprint
#        supplementary docs
# When:  check file existence at both old and new canonical paths
# Then:  File exists at new canonical path (skills/sprint/docs/);
#        file does NOT exist at old dev-artifact path (docs/designs/)
#
# Rule 5 category: Referential integrity — the file path is the structural
# contract. Agents reference cascade-replan-protocol.md by path; that path
# must be resolvable at the canonical skill location.
# ===========================================================================
echo "--- test_cascade_replan_at_skill_path ---"

# Check file exists at canonical skill path
if [[ -f "$CASCADE_REPLAN_SKILL_PATH" ]]; then
    assert_eq "test_cascade_replan_at_skill_path: exists at skills/sprint/docs/" "exists" "exists"
else
    assert_eq "test_cascade_replan_at_skill_path: exists at skills/sprint/docs/" "exists" "missing"
fi

# Check file does NOT exist at old designs path (misplacement detection)
if [[ -f "$CASCADE_REPLAN_OLD_PATH" ]]; then
    assert_eq "test_cascade_replan_at_skill_path: absent from docs/designs/" "absent" "present"
else
    assert_eq "test_cascade_replan_at_skill_path: absent from docs/designs/" "absent" "absent"
fi

# ===========================================================================
# test_no_dev_artifact_paths_in_plugin_agents_skills
#
# Grep gate DD7: verify git grep -r for dev-artifact path prefixes across
# plugins/dso/agents/ and plugins/dso/skills/ returns zero matches.
#
# Given: all agent and skill files in plugins/dso/
# When:  run git grep for three dev-artifact path patterns
# Then:  zero matches (grep exit code 1 = no matches = pass)
#
# Rule 5 category: Referential integrity — the absence of dev-artifact paths
# in agent/skill instruction files is the structural boundary contract.
# Agent files referencing plugins/dso/docs/designs/, plugins/dso/docs/findings/,
# or plugins/dso/docs/archive/ encode dev-team artifact paths inside LLM
# instruction files, violating the plugin boundary policy.
# ===========================================================================
echo "--- test_no_dev_artifact_paths_in_plugin_agents_skills ---"

AGENTS_DIR="$PLUGIN_ROOT/plugins/dso/agents"
SKILLS_DIR="$PLUGIN_ROOT/plugins/dso/skills"

# Run git grep for all three dev-artifact path patterns across agents/ and skills/
# Exit code 0 = matches found (FAIL); exit code 1 = no matches (PASS)
if git -C "$PLUGIN_ROOT" grep -r \
    -e "plugins/dso/docs/designs" \
    -e "plugins/dso/docs/findings" \
    -e "plugins/dso/docs/archive" \
    -- "$AGENTS_DIR" "$SKILLS_DIR" 2>/dev/null | grep -v "^Binary"; then
    # Matches found — violation
    assert_eq "test_no_dev_artifact_paths_in_plugin_agents_skills: zero dev-artifact paths in agents+skills" "0_matches" "matches_found"
else
    # No matches — boundary clean
    assert_eq "test_no_dev_artifact_paths_in_plugin_agents_skills: zero dev-artifact paths in agents+skills" "0_matches" "0_matches"
fi

print_summary
