#!/usr/bin/env bash
# tests/hooks/test-fix-bug-empirical-validation.sh
# Verifies that /dso:fix-bug SKILL.md and investigation prompt templates
# require empirical validation of assumptions before proposing fixes.
#
# Bug: 1a99-307b — fix-bug skill makes untested assumptions during
# execution instead of validating hypotheses experimentally.
#
# Usage:
#   bash tests/hooks/test-fix-bug-empirical-validation.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

SKILL_FILE="$DSO_PLUGIN_DIR/skills/fix-bug/SKILL.md"
PROMPTS_DIR="$DSO_PLUGIN_DIR/skills/fix-bug/prompts"

echo "=== test-fix-bug-empirical-validation.sh ==="

# ---------------------------------------------------------------
# Test 1: SKILL.md contains an Empirical Validation Directive section
# ---------------------------------------------------------------
if grep -q "## Empirical Validation Directive" "$SKILL_FILE"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_skill_has_empirical_validation_directive_section" "present" "$actual"

# ---------------------------------------------------------------
# Test 2: The directive requires running actual commands before proposing
# ---------------------------------------------------------------
if grep -qi "run.*actual.*command\|execute.*tool\|run.*--help\|test.*actual.*behavior" "$SKILL_FILE"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_skill_directive_requires_running_commands" "present" "$actual"

# ---------------------------------------------------------------
# Test 3: The directive distinguishes docs-say from tested-and-works
# ---------------------------------------------------------------
if grep -qi "docs.*say\|documentation.*claim\|documented.*vs.*observed\|stated.*vs.*actual" "$SKILL_FILE"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_skill_directive_distinguishes_docs_vs_tested" "present" "$actual"

# ---------------------------------------------------------------
# Test 4: basic-investigation.md contains an Empirical Validation step
# ---------------------------------------------------------------
BASIC_PROMPT="$PROMPTS_DIR/basic-investigation.md"
if grep -q "Empirical Validation" "$BASIC_PROMPT"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_basic_prompt_has_empirical_validation_step" "present" "$actual"

# ---------------------------------------------------------------
# Test 5: intermediate-investigation-fallback.md contains an Empirical Validation step
# ---------------------------------------------------------------
INTERMEDIATE_PROMPT="$PROMPTS_DIR/intermediate-investigation-fallback.md"
if grep -q "Empirical Validation" "$INTERMEDIATE_PROMPT"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_intermediate_fallback_prompt_has_empirical_validation_step" "present" "$actual"

# ---------------------------------------------------------------
# Test 6: intermediate-investigation.md contains an Empirical Validation step
# ---------------------------------------------------------------
INTERMEDIATE_FULL="$PROMPTS_DIR/intermediate-investigation.md"
if grep -q "Empirical Validation" "$INTERMEDIATE_FULL"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_intermediate_prompt_has_empirical_validation_step" "present" "$actual"

# ---------------------------------------------------------------
# Test 7: advanced-investigation-agent-a.md contains an Empirical Validation step
# ---------------------------------------------------------------
ADVANCED_A="$PROMPTS_DIR/advanced-investigation-agent-a.md"
if grep -q "Empirical Validation" "$ADVANCED_A"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_advanced_agent_a_has_empirical_validation_step" "present" "$actual"

# ---------------------------------------------------------------
# Test 8: advanced-investigation-agent-b.md contains an Empirical Validation step
# ---------------------------------------------------------------
ADVANCED_B="$PROMPTS_DIR/advanced-investigation-agent-b.md"
if grep -q "Empirical Validation" "$ADVANCED_B"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_advanced_agent_b_has_empirical_validation_step" "present" "$actual"

# ---------------------------------------------------------------
# Test 9: cluster-investigation.md contains an Empirical Validation step
# ---------------------------------------------------------------
CLUSTER="$PROMPTS_DIR/cluster-investigation.md"
if grep -q "Empirical Validation" "$CLUSTER"; then
    actual="present"
else
    actual="missing"
fi
assert_eq "test_cluster_prompt_has_empirical_validation_step" "present" "$actual"

print_summary
