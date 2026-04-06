#!/usr/bin/env bash
# tests/scripts/test-approach-decision-maker-agent.sh
# Behavioral contract tests for the dso:approach-decision-maker agent definition.
#
# These tests verify that the agent file at plugins/dso/agents/approach-decision-maker.md
# encodes the required behavioral contracts: frontmatter with name/model, five evaluation
# dimensions, context hierarchy, anti-pattern detection, nesting prohibition (inline DO NOT
# dispatch instruction), and ADR-style output format with counter-proposal capability.
#
# All tests FAIL (RED) until the agent file is created with correct content.
#
# Usage: bash tests/scripts/test-approach-decision-maker-agent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/plugins/dso/agents/approach-decision-maker.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-approach-decision-maker-agent.sh ==="

# ── test_agent_file_exists ───────────────────────────────────────────────────
# The agent file must exist and be non-empty.
# RED: file does not exist yet — both assertions fail.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_agent_file_exists: file present at plugins/dso/agents/approach-decision-maker.md" "exists" "$actual_exists"

if [[ -f "$AGENT_FILE" && -s "$AGENT_FILE" ]]; then
    actual_nonempty="nonempty"
else
    actual_nonempty="empty-or-missing"
fi
assert_eq "test_agent_file_exists: file is non-empty" "nonempty" "$actual_nonempty"
assert_pass_if_clean "test_agent_file_exists"

# ── test_frontmatter_name ───────────────────────────────────────────────────
# YAML frontmatter must contain name: approach-decision-maker.
# Contract: callers rely on the routing name to dispatch correctly.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    frontmatter=$(awk '/^---/{c++; if(c==2) exit} c{print}' "$AGENT_FILE")
    if grep -qE '^name:[[:space:]]*approach-decision-maker[[:space:]]*$' <<< "$frontmatter"; then
        actual_name="present"
    else
        actual_name="missing"
    fi
else
    actual_name="missing"
fi
assert_eq "test_frontmatter_name: name is approach-decision-maker" "present" "$actual_name"
assert_pass_if_clean "test_frontmatter_name"

# ── test_frontmatter_model_opus ─────────────────────────────────────────────
# YAML frontmatter must contain model: opus.
# Contract: approach decisions are high-blast-radius and require opus-tier reasoning.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    frontmatter=$(awk '/^---/{c++; if(c==2) exit} c{print}' "$AGENT_FILE")
    if grep -qE '^model:[[:space:]]*opus[[:space:]]*$' <<< "$frontmatter"; then
        actual_model="present"
    else
        actual_model="missing"
    fi
else
    actual_model="missing"
fi
assert_eq "test_frontmatter_model_opus: model is opus" "present" "$actual_model"
assert_pass_if_clean "test_frontmatter_model_opus"

# ── test_five_evaluation_dimensions ─────────────────────────────────────────
# All 5 evaluation dimensions must be named in the agent file.
# Contract: the agent must evaluate every approach against all 5 dimensions.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
else
    file_content=""
fi

DIMENSIONS=(
    "codebase alignment"
    "blast radius"
    "testability"
    "simplicity"
    "robustness"
)

for dim in "${DIMENSIONS[@]}"; do
    shopt -s nocasematch
    if [[ "$file_content" =~ $dim ]]; then
        actual_dim="present"
    else
        actual_dim="missing"
    fi
    shopt -u nocasematch
    assert_eq "test_five_evaluation_dimensions: '$dim' present" "present" "$actual_dim"
done
assert_pass_if_clean "test_five_evaluation_dimensions"

# ── test_context_hierarchy ──────────────────────────────────────────────────
# The agent must contain a context hierarchy section with epic, story, and
# considerations levels.
# Contract: the agent must understand the ticket hierarchy to scope decisions.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    shopt -s nocasematch
    if [[ "$file_content" =~ epic ]]; then
        actual_epic="present"
    else
        actual_epic="missing"
    fi
    if [[ "$file_content" =~ story ]]; then
        actual_story="present"
    else
        actual_story="missing"
    fi
    if [[ "$file_content" =~ consideration ]]; then
        actual_considerations="present"
    else
        actual_considerations="missing"
    fi
    # Must reference "context hierarchy" or "context" + "hierarchy" nearby
    if [[ "$file_content" =~ context.hierarch|hierarch.*context ]]; then
        actual_section="present"
    else
        actual_section="missing"
    fi
    shopt -u nocasematch
else
    actual_epic="missing"
    actual_story="missing"
    actual_considerations="missing"
    actual_section="missing"
fi
assert_eq "test_context_hierarchy: epic level referenced" "present" "$actual_epic"
assert_eq "test_context_hierarchy: story level referenced" "present" "$actual_story"
assert_eq "test_context_hierarchy: considerations level referenced" "present" "$actual_considerations"
assert_eq "test_context_hierarchy: context hierarchy section present" "present" "$actual_section"
assert_pass_if_clean "test_context_hierarchy"

# ── test_antipattern_detection ──────────────────────────────────────────────
# The agent must contain anti-pattern detection covering at minimum:
# golden hammer, premature abstraction, and cargo cult.
# Contract: the agent must flag known bad approaches before recommending them.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
else
    file_content=""
fi

ANTIPATTERNS=(
    "golden hammer"
    "premature abstraction"
    "cargo cult"
)

for ap in "${ANTIPATTERNS[@]}"; do
    shopt -s nocasematch
    if [[ "$file_content" =~ $ap ]]; then
        actual_ap="present"
    else
        actual_ap="missing"
    fi
    shopt -u nocasematch
    assert_eq "test_antipattern_detection: '$ap' present" "present" "$actual_ap"
done

# Must reference "anti-pattern" or "antipattern" as a section/concept
if [[ -n "$file_content" ]]; then
    shopt -s nocasematch; if [[ "$file_content" =~ anti.pattern|antipattern ]]; then
        actual_section="present"
    else
        actual_section="missing"
    fi; shopt -u nocasematch
else
    actual_section="missing"
fi
assert_eq "test_antipattern_detection: anti-pattern section present" "present" "$actual_section"
assert_pass_if_clean "test_antipattern_detection"

# ── test_nesting_prohibition ────────────────────────────────────────────────
# The agent must contain an inline nesting prohibition that names Task dispatches
# as prohibited AND Read/Grep/Glob as allowed tools.
# AC amendment: NOT a <SUB-AGENT-GUARD> block — this is a pure evaluator agent
# without Agent tool access. Uses inline "DO NOT dispatch" instruction instead.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    # Must prohibit Task dispatches (nesting)
    shopt -s nocasematch; if [[ "$file_content" =~ do\ not.*dispatch|never.*dispatch|must\ not.*dispatch|prohibit.*dispatch|no.*task.*dispatch|do\ not.*task ]]; then
        actual_prohibition="present"
    else
        actual_prohibition="missing"
    fi; shopt -u nocasematch
    # Must allow Read/Grep/Glob as tools
    shopt -s nocasematch
    if [[ "$file_content" =~ Read ]]; then
        actual_read="present"
    else
        actual_read="missing"
    fi
    if [[ "$file_content" =~ Grep ]]; then
        actual_grep="present"
    else
        actual_grep="missing"
    fi
    if [[ "$file_content" =~ Glob ]]; then
        actual_glob="present"
    else
        actual_glob="missing"
    fi
    # Must NOT contain SUB-AGENT-GUARD (per AC amendment)
    if [[ "$file_content" =~ SUB-AGENT-GUARD ]]; then
        actual_no_guard="guard-found"
    else
        actual_no_guard="no-guard"
    fi
    shopt -u nocasematch
else
    actual_prohibition="missing"
    actual_read="missing"
    actual_grep="missing"
    actual_glob="missing"
    actual_no_guard="no-guard"
fi
assert_eq "test_nesting_prohibition: dispatch prohibition present" "present" "$actual_prohibition"
assert_eq "test_nesting_prohibition: Read tool named as allowed" "present" "$actual_read"
assert_eq "test_nesting_prohibition: Grep tool named as allowed" "present" "$actual_grep"
assert_eq "test_nesting_prohibition: Glob tool named as allowed" "present" "$actual_glob"
assert_eq "test_nesting_prohibition: no SUB-AGENT-GUARD block (evaluator agent)" "no-guard" "$actual_no_guard"
assert_pass_if_clean "test_nesting_prohibition"

# ── test_adr_output_format ──────────────────────────────────────────────────
# The agent must describe ADR-style output containing Context, Decision, and
# Consequences sections, AND must describe counter-proposal capability.
# Contract: downstream consumers parse these structured sections.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    shopt -s nocasematch
    if [[ "$file_content" =~ Context ]]; then
        actual_context="present"
    else
        actual_context="missing"
    fi
    if [[ "$file_content" =~ Decision ]]; then
        actual_decision="present"
    else
        actual_decision="missing"
    fi
    if [[ "$file_content" =~ Consequences ]]; then
        actual_consequences="present"
    else
        actual_consequences="missing"
    fi
    if [[ "$file_content" =~ counter.proposal|counter\ proposal|alternative.*proposal|propose.*alternative ]]; then
        actual_counter="present"
    else
        actual_counter="missing"
    fi
    shopt -u nocasematch
else
    actual_context="missing"
    actual_decision="missing"
    actual_consequences="missing"
    actual_counter="missing"
fi
assert_eq "test_adr_output_format: Context section referenced" "present" "$actual_context"
assert_eq "test_adr_output_format: Decision section referenced" "present" "$actual_decision"
assert_eq "test_adr_output_format: Consequences section referenced" "present" "$actual_consequences"
assert_eq "test_adr_output_format: counter-proposal capability described" "present" "$actual_counter"
assert_pass_if_clean "test_adr_output_format"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
