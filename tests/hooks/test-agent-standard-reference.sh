#!/usr/bin/env bash
# tests/hooks/test-agent-standard-reference.sh
# Structural referential-integrity tests for agent behavioral-testing-standard.md references.
#
# These tests verify ONLY structural boundary contracts per Rule 5 of the behavioral
# testing standard: referential integrity (path references exist, referenced files exist).
# They do NOT grep instruction file body text for content assertions.
#
# What we test (structural boundary — Rule 5 acceptable categories):
#   - Path reference to behavioral-testing-standard.md appears in each target agent file
#     (referential integrity: the path IS the integration interface agents use to load the standard)
#   - The referenced file (behavioral-testing-standard.md) exists and is readable
#   - behavioral-testing-standard.md contains a "## Rule 5" section heading
#     (contract schema validation: section heading is a machine-navigable structural marker)
#
# What we do NOT test (content assertions prohibited by Rule 5):
#   - Specific phrases or wording inside instruction file body text
#   - LLM behavioral correctness (non-deterministic)
#
# Usage:
#   bash tests/hooks/test-agent-standard-reference.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

STANDARD_REL_PATH="plugins/dso/skills/shared/prompts/behavioral-testing-standard.md"
STANDARD_FILE="$PLUGIN_ROOT/$STANDARD_REL_PATH"

echo "=== test-agent-standard-reference.sh ==="

# ---------------------------------------------------------------------------
# Helper: assert_agent_references_standard <agent-name>
# Checks that the agent file contains a path reference to behavioral-testing-standard.md.
# This is a referential-integrity check: the path reference is the deterministic
# integration interface used by agents to load the standard at runtime.
# ---------------------------------------------------------------------------
assert_agent_references_standard() {
    local agent_name="$1"
    local agent_file="$PLUGIN_ROOT/plugins/dso/agents/${agent_name}.md"
    local label_exists="test_${agent_name//-/_}_agent_file_exists"
    local label_ref="test_${agent_name//-/_}_references_behavioral_testing_standard"

    # Verify the agent file itself exists
    if [[ -f "$agent_file" ]]; then
        assert_eq "$label_exists" "present" "present"
    else
        assert_eq "$label_exists" "present" "missing"
        # No point checking path reference if file is absent
        assert_eq "$label_ref" "reference_present" "agent_file_missing"
        return
    fi

    # Verify the path to behavioral-testing-standard.md appears in the agent file.
    # The path IS the structural contract — agents use it to locate and load the standard.
    if grep -qF "$STANDARD_REL_PATH" "$agent_file" 2>/dev/null; then
        assert_eq "$label_ref" "reference_present" "reference_present"
    else
        assert_eq "$label_ref" "reference_present" "reference_missing"
    fi
}

# ===========================================================================
# test: red-test-writer.md references behavioral-testing-standard.md
# red-test-writer is a primary test-writing agent; it must load the standard
# to apply Rule 1 (coverage check) per its Section 3 Step 1.
# ===========================================================================
echo "--- red-test-writer ---"
assert_agent_references_standard "red-test-writer"

# ===========================================================================
# test: code-reviewer-test-quality.md references behavioral-testing-standard.md
# code-reviewer-test-quality applies the standard as its review authority;
# the path reference is the hook that loads the standard before evaluation.
# ===========================================================================
echo "--- code-reviewer-test-quality ---"
assert_agent_references_standard "code-reviewer-test-quality"

# ===========================================================================
# test: red-test-evaluator.md references behavioral-testing-standard.md
# red-test-evaluator consults the standard as baseline rejection criteria
# per its Section 3 verdict decision logic.
# ===========================================================================
echo "--- red-test-evaluator ---"
assert_agent_references_standard "red-test-evaluator"

# ===========================================================================
# test: behavioral-testing-standard.md contains "## Rule 5" section heading
# Contract schema validation: ## Rule 5 is a structural marker that agents
# navigate to load the instruction-file testing boundary rules.
# ===========================================================================
echo "--- behavioral-testing-standard Rule 5 heading ---"
if grep -q "^## Rule 5" "$STANDARD_FILE" 2>/dev/null; then
    assert_eq "test_behavioral_testing_standard_has_rule5_heading" "present" "present"
else
    assert_eq "test_behavioral_testing_standard_has_rule5_heading" "present" "missing"
fi

print_summary
