#!/usr/bin/env bash
# tests/scripts/test-bot-psychologist-agent.sh
# Behavioral contract tests for the dso:bot-psychologist agent definition.
#
# These tests verify that the agent file at plugins/dso/agents/bot-psychologist.md
# encodes the required behavioral contracts: 17-item failure taxonomy, 5 RCA probes,
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
    actual_name="missing"; actual_model="missing"; actual_desc="missing"
    while IFS= read -r _line; do
        [[ "$_line" =~ ^name:[[:space:]]*bot-psychologist[[:space:]]*$ ]] && actual_name="present"
        [[ "$_line" =~ ^model:[[:space:]]*sonnet[[:space:]]*$ ]] && actual_model="present"
        [[ "$_line" =~ ^description: ]] && actual_desc="present"
    done <<< "$frontmatter"
else
    actual_name="missing"
    actual_model="missing"
    actual_desc="missing"
fi
assert_eq "test_frontmatter_fields: name is bot-psychologist" "present" "$actual_name"
assert_eq "test_frontmatter_fields: model is sonnet" "present" "$actual_model"
assert_eq "test_frontmatter_fields: description field present" "present" "$actual_desc"
assert_pass_if_clean "test_frontmatter_fields"

# ── test_failure_taxonomy_structure ──────────────────────────────────────────
# Structural contract: the agent file defines a Failure Taxonomy section that
# enumerates exactly 17 numbered failure modes. We assert STRUCTURE (section
# heading present + numbered-item count), NOT individual prose item names, so
# benign rewording of a mode's description does not break the test. Per the
# Behavioral Testing Standard Rule 5 Structural-Artifact Exception, structural
# validation is the authorized testing boundary for a non-executable instruction
# file — verify contract shape, not prose content.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    if grep -qE '^## Failure Taxonomy' "$AGENT_FILE"; then
        actual_section="present"
    else
        actual_section="missing"
    fi
    # Count top-level numbered items between the Failure Taxonomy heading and the
    # next "## " heading. This asserts the taxonomy's cardinality (the contract),
    # independent of how any individual mode is worded.
    taxonomy_count=$(awk '
        /^## Failure Taxonomy/ { insec=1; next }
        insec && /^## / { insec=0 }
        insec && /^[0-9]+\. / { n++ }
        END { print n+0 }
    ' "$AGENT_FILE")
else
    actual_section="missing"; taxonomy_count=0
fi
assert_eq "test_failure_taxonomy_structure: Failure Taxonomy section present" "present" "$actual_section"
assert_eq "test_failure_taxonomy_structure: enumerates 17 numbered failure modes" "17" "$taxonomy_count"
assert_pass_if_clean "test_failure_taxonomy_structure"

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
    _tmp="$file_content"; shopt -s nocasematch
    if [[ "$_tmp" == *"$probe"* ]]; then
        actual_probe="present"
    else
        actual_probe="missing"
    fi; shopt -u nocasematch
    assert_eq "test_rca_probes_all_5: '$probe' present" "present" "$actual_probe"
done
assert_pass_if_clean "test_rca_probes_all_5"

# ── test_result_schema_root_cause_and_confidence ─────────────────────────────
# RESULT schema must reference ROOT_CAUSE and confidence fields.
# Contract: callers expect these machine-parseable top-level fields in every diagnosis.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    _tmp="$file_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ ROOT_CAUSE|root_cause ]]; then
        actual_root_cause="present"
    else
        actual_root_cause="missing"
    fi
    if [[ "$_tmp" == *"confidence"* ]]; then
        actual_confidence="present"
    else
        actual_confidence="missing"
    fi
    if [[ "$_tmp" =~ proposed_fixes|proposed.fixes ]]; then
        actual_fixes="present"
    else
        actual_fixes="missing"
    fi
    if [[ "$_tmp" == *"affirmative_framing"* ]]; then
        actual_affirmative="present"
    else
        actual_affirmative="missing"
    fi; shopt -u nocasematch
else
    actual_root_cause="missing"
    actual_confidence="missing"
    actual_fixes="missing"
    actual_affirmative="missing"
fi
assert_eq "test_result_schema_root_cause_and_confidence: ROOT_CAUSE field present" "present" "$actual_root_cause"
assert_eq "test_result_schema_root_cause_and_confidence: confidence field present" "present" "$actual_confidence"
assert_eq "test_result_schema_root_cause_and_confidence: proposed_fixes field present" "present" "$actual_fixes"
assert_eq "test_result_schema_root_cause_and_confidence: affirmative_framing field present (Pink-Elephant fix-modifier contract)" "present" "$actual_affirmative"
assert_pass_if_clean "test_result_schema_root_cause_and_confidence"

# ── test_result_schema_hypothesis_tests_subfields ────────────────────────────
# hypothesis_tests sub-fields must match fix-bug format exactly:
# hypothesis, test, observed, verdict.
# Contract: downstream /dso:fix-bug consumers parse these exact field names.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    _tmp="$file_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ hypothesis_tests|hypothesis.tests ]]; then
        actual_ht="present"
    else
        actual_ht="missing"
    fi
    if [[ "$_tmp" == *"hypothesis"* ]]; then
        actual_hypothesis="present"
    else
        actual_hypothesis="missing"
    fi
    if [[ "$_tmp" =~ [[:space:]]test[[:space:]] ]] || [[ "$_tmp" =~ [[:space:]]test$|^test[[:space:]] ]]; then
        actual_test_field="present"
    else
        actual_test_field="missing"
    fi
    if [[ "$_tmp" == *"observed"* ]]; then
        actual_observed="present"
    else
        actual_observed="missing"
    fi
    if [[ "$_tmp" == *"verdict"* ]]; then
        actual_verdict="present"
    else
        actual_verdict="missing"
    fi; shopt -u nocasematch
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

# ── test_iterative_loop_defined ──────────────────────────────────────────────
# The agent must describe an iterative hypothesis-experiment-analyze loop.
# Contract: the agent must not propose fixes without experimental confirmation —
# this is the core behavioral invariant distinguishing it from a simple classifier.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    _tmp="$file_content"; shopt -s nocasematch
    if [[ "$_tmp" == *"hypothesis"* ]]; then
        actual_hyp="present"
    else
        actual_hyp="missing"
    fi
    if [[ "$_tmp" =~ experiment|probe|test ]]; then
        actual_exp="present"
    else
        actual_exp="missing"
    fi
    if [[ "$_tmp" =~ iterative|loop|step.*hypothesis|hypothesis.*step|proven|confirmed|disproven ]]; then
        actual_iter="present"
    else
        actual_iter="missing"
    fi; shopt -u nocasematch
else
    actual_hyp="missing"
    actual_exp="missing"
    actual_iter="missing"
fi
assert_eq "test_iterative_loop_defined: hypothesis concept referenced" "present" "$actual_hyp"
assert_eq "test_iterative_loop_defined: experiment/probe/test concept referenced" "present" "$actual_exp"
assert_eq "test_iterative_loop_defined: iterative loop or proven/confirmed concept present" "present" "$actual_iter"
assert_pass_if_clean "test_iterative_loop_defined"

# ── test_self_execution_and_stop_condition ──────────────────────────────────
# The agent must instruct self-execution of probes using available tools and
# define a stop condition (AWAITING_RESULTS) when a probe cannot be self-executed.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    _tmp="$file_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ execute.*yourself|execute.*probe.*yourself|self.*execut|run.*yourself|your.*available.*tools ]]; then
        actual_self_exec="present"
    else
        actual_self_exec="missing"
    fi
    if [[ "$_tmp" =~ AWAITING_RESULTS ]]; then
        actual_stop="present"
    else
        actual_stop="missing"
    fi; shopt -u nocasematch
else
    actual_self_exec="missing"
    actual_stop="missing"
fi
assert_eq "test_self_execution_and_stop_condition: self-execution instruction present" "present" "$actual_self_exec"
assert_eq "test_self_execution_and_stop_condition: AWAITING_RESULTS stop condition present" "present" "$actual_stop"
assert_pass_if_clean "test_self_execution_and_stop_condition"

# ── test_no_fix_before_proof_constraint ──────────────────────────────────────
# The agent must explicitly constrain itself from proposing a fix before experimental
# proof of the root cause.
# Contract: prevents premature / speculative fixes — observable as a negative directive.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    _tmp="$file_content"; shopt -s nocasematch
    if [[ "$_tmp" =~ not.*fix|fix.*not|never.*fix|fix.*unconfirmed|fix.*proven|proven.*fix|do\ not.*propose.*fix|do\ not.*assume ]]; then
        actual_constraint="present"
    else
        actual_constraint="missing"
    fi; shopt -u nocasematch
else
    actual_constraint="missing"
fi
assert_eq "test_no_fix_before_proof_constraint: no-fix-before-proof negative directive present" "present" "$actual_constraint"
assert_pass_if_clean "test_no_fix_before_proof_constraint"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
