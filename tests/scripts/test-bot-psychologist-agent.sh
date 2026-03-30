#!/usr/bin/env bash
# tests/scripts/test-bot-psychologist-agent.sh
# Behavioral contract tests for the dso:bot-psychologist agent definition.
#
# These tests verify that the agent file at plugins/dso/agents/bot-psychologist.md
# encodes the required behavioral contracts: 15-item failure taxonomy, 5 RCA probes,
# RESULT schema with hypothesis_tests sub-fields matching fix-bug format, frontmatter
# with correct name/model, and SUB-AGENT-GUARD block.
#
# All tests FAIL (RED) until the agent file is created with correct content.
#
# Usage: bash tests/scripts/test-bot-psychologist-agent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/plugins/dso/agents/bot-psychologist.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-bot-psychologist-agent.sh ==="

# ── test_agent_file_exists ───────────────────────────────────────────────────
# The agent file must exist and be non-empty.
# RED: file does not exist yet — both assertions fail.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_agent_file_exists: file present at plugins/dso/agents/bot-psychologist.md" "exists" "$actual_exists"

if [[ -f "$AGENT_FILE" && -s "$AGENT_FILE" ]]; then
    actual_nonempty="nonempty"
else
    actual_nonempty="empty-or-missing"
fi
assert_eq "test_agent_file_exists: file is non-empty" "nonempty" "$actual_nonempty"
assert_pass_if_clean "test_agent_file_exists"

# ── test_frontmatter_fields ──────────────────────────────────────────────────
# YAML frontmatter must contain name: bot-psychologist, model: sonnet, description field.
# Contract: callers rely on the routing name and model tier to dispatch correctly.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    frontmatter=$(awk '/^---/{c++; if(c==2) exit} c{print}' "$AGENT_FILE")
    if echo "$frontmatter" | grep -qE '^name:[[:space:]]*bot-psychologist[[:space:]]*$'; then
        actual_name="present"
    else
        actual_name="missing"
    fi
    if echo "$frontmatter" | grep -qE '^model:[[:space:]]*sonnet[[:space:]]*$'; then
        actual_model="present"
    else
        actual_model="missing"
    fi
    if echo "$frontmatter" | grep -qE '^description:'; then
        actual_desc="present"
    else
        actual_desc="missing"
    fi
else
    actual_name="missing"
    actual_model="missing"
    actual_desc="missing"
fi
assert_eq "test_frontmatter_fields: name is bot-psychologist" "present" "$actual_name"
assert_eq "test_frontmatter_fields: model is sonnet" "present" "$actual_model"
assert_eq "test_frontmatter_fields: description field present" "present" "$actual_desc"
assert_pass_if_clean "test_frontmatter_fields"

# ── test_failure_taxonomy_all_15_items ───────────────────────────────────────
# All 15 taxonomy items must be named in the agent file.
# Contract: the agent must reference every failure mode it is capable of diagnosing.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
else
    file_content=""
fi

TAXONOMY_ITEMS=(
    "Structured Output Collapse"
    "Tool-Calling Schema Drift"
    "Silent Instruction Truncation"
    "Context Flooding"
    "Multi-File State De-sync"
    "Termination Awareness Failure"
    "Multi-Step Reasoning Drift"
    "Verbosity"
    "Sycophancy"
    "Brittle API Mapping"
    "Positional Bias"
    "Non-Deterministic Logic"
    "Phantom Capability Hallucination"
    "Instruction Leaking"
    "Confidence Calibration Failure"
)

for item in "${TAXONOMY_ITEMS[@]}"; do
    if echo "$file_content" | grep -qi "$item"; then
        actual_item="present"
    else
        actual_item="missing"
    fi
    assert_eq "test_failure_taxonomy_all_15_items: '$item' present" "present" "$actual_item"
done
assert_pass_if_clean "test_failure_taxonomy_all_15_items"

# ── test_rca_probes_all_5 ────────────────────────────────────────────────────
# All 5 RCA probes must be named in the agent file.
# Contract: the agent must be able to select from the full probe toolkit.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
else
    file_content=""
fi

RCA_PROBES=(
    "Gold Context Test"
    "Closed-Book Test"
    "Prompt Perturbation"
    "Sycophancy Probe"
    "State-Check Probe"
)

for probe in "${RCA_PROBES[@]}"; do
    if echo "$file_content" | grep -qi "$probe"; then
        actual_probe="present"
    else
        actual_probe="missing"
    fi
    assert_eq "test_rca_probes_all_5: '$probe' present" "present" "$actual_probe"
done
assert_pass_if_clean "test_rca_probes_all_5"

# ── test_result_schema_root_cause_and_confidence ─────────────────────────────
# RESULT schema must reference ROOT_CAUSE and confidence fields.
# Contract: callers expect these machine-parseable top-level fields in every diagnosis.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qiE "ROOT_CAUSE|root_cause"; then
        actual_root_cause="present"
    else
        actual_root_cause="missing"
    fi
    if echo "$file_content" | grep -qi "confidence"; then
        actual_confidence="present"
    else
        actual_confidence="missing"
    fi
    if echo "$file_content" | grep -qi "proposed_fixes\|proposed.fixes"; then
        actual_fixes="present"
    else
        actual_fixes="missing"
    fi
else
    actual_root_cause="missing"
    actual_confidence="missing"
    actual_fixes="missing"
fi
assert_eq "test_result_schema_root_cause_and_confidence: ROOT_CAUSE field present" "present" "$actual_root_cause"
assert_eq "test_result_schema_root_cause_and_confidence: confidence field present" "present" "$actual_confidence"
assert_eq "test_result_schema_root_cause_and_confidence: proposed_fixes field present" "present" "$actual_fixes"
assert_pass_if_clean "test_result_schema_root_cause_and_confidence"

# ── test_result_schema_hypothesis_tests_subfields ────────────────────────────
# hypothesis_tests sub-fields must match fix-bug format exactly:
# hypothesis, test, observed, verdict.
# Contract: downstream /dso:fix-bug consumers parse these exact field names.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qi "hypothesis_tests\|hypothesis.tests"; then
        actual_ht="present"
    else
        actual_ht="missing"
    fi
    if echo "$file_content" | grep -qi "hypothesis"; then
        actual_hypothesis="present"
    else
        actual_hypothesis="missing"
    fi
    if echo "$file_content" | grep -qiE "\btest\b"; then
        actual_test_field="present"
    else
        actual_test_field="missing"
    fi
    if echo "$file_content" | grep -qi "observed"; then
        actual_observed="present"
    else
        actual_observed="missing"
    fi
    if echo "$file_content" | grep -qi "verdict"; then
        actual_verdict="present"
    else
        actual_verdict="missing"
    fi
else
    actual_ht="missing"
    actual_hypothesis="missing"
    actual_test_field="missing"
    actual_observed="missing"
    actual_verdict="missing"
fi
assert_eq "test_result_schema_hypothesis_tests_subfields: hypothesis_tests field present" "present" "$actual_ht"
assert_eq "test_result_schema_hypothesis_tests_subfields: hypothesis sub-field present" "present" "$actual_hypothesis"
assert_eq "test_result_schema_hypothesis_tests_subfields: test sub-field present" "present" "$actual_test_field"
assert_eq "test_result_schema_hypothesis_tests_subfields: observed sub-field present" "present" "$actual_observed"
assert_eq "test_result_schema_hypothesis_tests_subfields: verdict sub-field present" "present" "$actual_verdict"
assert_pass_if_clean "test_result_schema_hypothesis_tests_subfields"

# ── test_sub_agent_guard_present ─────────────────────────────────────────────
# The agent file must contain a SUB-AGENT-GUARD block.
# Contract: architectural design rule requires all agents that require user interaction
# or direct Agent-tool access to declare a guard preventing nested sub-agent dispatch.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qi "SUB-AGENT-GUARD"; then
        actual_guard="present"
    else
        actual_guard="missing"
    fi
else
    actual_guard="missing"
fi
assert_eq "test_sub_agent_guard_present: SUB-AGENT-GUARD block declared" "present" "$actual_guard"
assert_pass_if_clean "test_sub_agent_guard_present"

# ── test_iterative_loop_defined ──────────────────────────────────────────────
# The agent must describe an iterative hypothesis-experiment-analyze loop.
# Contract: the agent must not propose fixes without experimental confirmation —
# this is the core behavioral invariant distinguishing it from a simple classifier.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qi "hypothesis"; then
        actual_hyp="present"
    else
        actual_hyp="missing"
    fi
    if echo "$file_content" | grep -qi "experiment\|probe\|test"; then
        actual_exp="present"
    else
        actual_exp="missing"
    fi
    if echo "$file_content" | grep -qi "iterative\|loop\|step.*hypothesis\|hypothesis.*step\|proven\|confirmed\|disproven"; then
        actual_iter="present"
    else
        actual_iter="missing"
    fi
else
    actual_hyp="missing"
    actual_exp="missing"
    actual_iter="missing"
fi
assert_eq "test_iterative_loop_defined: hypothesis concept referenced" "present" "$actual_hyp"
assert_eq "test_iterative_loop_defined: experiment/probe/test concept referenced" "present" "$actual_exp"
assert_eq "test_iterative_loop_defined: iterative loop or proven/confirmed concept present" "present" "$actual_iter"
assert_pass_if_clean "test_iterative_loop_defined"

# ── test_no_fix_before_proof_constraint ──────────────────────────────────────
# The agent must explicitly constrain itself from proposing a fix before experimental
# proof of the root cause.
# Contract: prevents premature / speculative fixes — observable as a negative directive.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qiE "not.*fix|fix.*not|never.*fix|fix.*unconfirmed|fix.*proven|proven.*fix|do not.*propose.*fix|do not.*assume"; then
        actual_constraint="present"
    else
        actual_constraint="missing"
    fi
else
    actual_constraint="missing"
fi
assert_eq "test_no_fix_before_proof_constraint: no-fix-before-proof negative directive present" "present" "$actual_constraint"
assert_pass_if_clean "test_no_fix_before_proof_constraint"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
