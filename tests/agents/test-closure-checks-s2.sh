#!/usr/bin/env bash
# tests/agents/test-closure-checks-s2.sh
# Behavioral tests for S2 (completion-verifier closure-checks + project_closure_hooks)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PLUGIN_ROOT/tests/lib/assert.sh"

CONTRACT_DOC="$PLUGIN_ROOT/plugins/dso/docs/contracts/end-state-item-validator.md"
VERIFIER_AGENT="$PLUGIN_ROOT/plugins/dso/agents/completion-verifier.md"

# ============================================================
# Group A: Contract document existence and schema fields
# (T1 — 2cbd-24af-8bb3-4226)
# RED: test_end_state_item_validator_contract_exists
# ============================================================

# test_verifier_contract_doc_exists: contract doc must exist
echo "--- test_verifier_contract_doc_exists ---"
# RED: test_end_state_item_validator_contract_exists
_snapshot_fail
_doc_exists="missing"
[[ -f "$CONTRACT_DOC" ]] && _doc_exists="present"
assert_eq "test_verifier_contract_doc_exists: file exists" "present" "$_doc_exists"
assert_pass_if_clean "test_verifier_contract_doc_exists"

# test_verifier_contract_version_field: must have contract_version=1 or contract_version: 1
echo "--- test_verifier_contract_version_field ---"
_snapshot_fail
grep -qE "contract_version[=:]\s*1" "$CONTRACT_DOC" 2>/dev/null
assert_eq "test_verifier_contract_version_field: contract_version=1 present" "0" "$?"
assert_pass_if_clean "test_verifier_contract_version_field"

# test_verifier_contract_input_schema: must document input schema section
echo "--- test_verifier_contract_input_schema ---"
_snapshot_fail
grep -qi "input" "$CONTRACT_DOC" 2>/dev/null
assert_eq "test_verifier_contract_input_schema: 'input' field present" "0" "$?"
assert_pass_if_clean "test_verifier_contract_input_schema"

# test_verifier_contract_output_schema: must document output schema section
echo "--- test_verifier_contract_output_schema ---"
_snapshot_fail
grep -qi "output" "$CONTRACT_DOC" 2>/dev/null
assert_eq "test_verifier_contract_output_schema: 'output' field present" "0" "$?"
assert_pass_if_clean "test_verifier_contract_output_schema"

# test_verifier_contract_valid_field: output must include valid bool field
echo "--- test_verifier_contract_valid_field ---"
_snapshot_fail
grep -q "valid" "$CONTRACT_DOC" 2>/dev/null
assert_eq "test_verifier_contract_valid_field: 'valid' field present" "0" "$?"
assert_pass_if_clean "test_verifier_contract_valid_field"

# test_verifier_contract_severity_field: output must include severity field (block|warn)
echo "--- test_verifier_contract_severity_field ---"
_snapshot_fail
grep -q "severity" "$CONTRACT_DOC" 2>/dev/null
assert_eq "test_verifier_contract_severity_field: 'severity' field present" "0" "$?"
assert_pass_if_clean "test_verifier_contract_severity_field"

# test_verifier_contract_worked_example: must include a worked example
echo "--- test_verifier_contract_worked_example ---"
_snapshot_fail
grep -qi "example" "$CONTRACT_DOC" 2>/dev/null
assert_eq "test_verifier_contract_worked_example: 'example' section present" "0" "$?"
assert_pass_if_clean "test_verifier_contract_worked_example"

# test_verifier_contract_versioning_policy: must include versioning policy section
echo "--- test_verifier_contract_versioning_policy ---"
_snapshot_fail
grep -qiE "versioning|Versioning Policy" "$CONTRACT_DOC" 2>/dev/null
assert_eq "test_verifier_contract_versioning_policy: 'Versioning Policy' section present" "0" "$?"
assert_pass_if_clean "test_verifier_contract_versioning_policy"

# test_verifier_contract_project_closure_hooks_key: must document project_closure_hooks config key
echo "--- test_verifier_contract_project_closure_hooks_key ---"
_snapshot_fail
grep -q "project_closure_hooks" "$CONTRACT_DOC" 2>/dev/null
assert_eq "test_verifier_contract_project_closure_hooks_key: 'project_closure_hooks' present" "0" "$?"
assert_pass_if_clean "test_verifier_contract_project_closure_hooks_key"

# ============================================================
# Group B: completion-verifier.md Step 3.5 project_closure_hooks
# (T2 — af14-d4ed-de6e-422f)
# RED: test_completion_verifier_step35_uses_project_closure_hooks
# ============================================================

# test_verifier_agent_hooks_config_key: completion-verifier.md references project_closure_hooks
echo "--- test_verifier_agent_hooks_config_key ---"
# RED: test_completion_verifier_step35_uses_project_closure_hooks
_snapshot_fail
grep -q "project_closure_hooks" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_agent_hooks_config_key: 'project_closure_hooks' in agent" "0" "$?"
assert_pass_if_clean "test_verifier_agent_hooks_config_key"

# test_verifier_agent_end_state_item_validator_ref: Step 3.5 references end-state-item-validator contract
echo "--- test_verifier_agent_end_state_item_validator_ref ---"
_snapshot_fail
grep -q "end-state-item-validator" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_agent_end_state_item_validator_ref: 'end-state-item-validator' referenced in agent" "0" "$?"
assert_pass_if_clean "test_verifier_agent_end_state_item_validator_ref"

# test_verifier_agent_hooks_absent_default: backward-compat rule — key absent = default SC9/SC13/SC14 behavior
echo "--- test_verifier_agent_hooks_absent_default ---"
_snapshot_fail
grep -qE "absent|not set|default" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_agent_hooks_absent_default: absent/default rule documented in agent" "0" "$?"
assert_pass_if_clean "test_verifier_agent_hooks_absent_default"

# test_verifier_parent_id_enumeration_scope: parent_id walk must document enumeration-only scope
echo "--- test_verifier_parent_id_enumeration_scope ---"
_snapshot_fail
grep -qiE "enumerat" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_parent_id_enumeration_scope: 'enumerate/enumeration' scope documented in agent" "0" "$?"
assert_pass_if_clean "test_verifier_parent_id_enumeration_scope"

# test_verifier_remediation_exclusion: remediation tasks excluded from parent_id walk
echo "--- test_verifier_remediation_exclusion ---"
_snapshot_fail
# Must have both "remediation" AND a negation nearby ("NOT" or "does not" or "excluded")
grep -qiE "remediation.*(NOT|does not|exclud|not included|skip)" "$VERIFIER_AGENT" 2>/dev/null || \
  grep -qiE "(NOT|does not|exclud|not included|skip).*remediation" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_remediation_exclusion: remediation exclusion from parent_id walk documented" "0" "$?"
assert_pass_if_clean "test_verifier_remediation_exclusion"

# ============================================================
# Group C: completion-verifier.md Closure Checks section reading
# (T3 — 257f-ffc5-24d4-42c5)
# RED: test_completion_verifier_reads_closure_checks
# ============================================================

# test_verifier_closure_checks_section_name: agent must reference "## Closure Checks" section
echo "--- test_verifier_closure_checks_section_name ---"
# RED: test_completion_verifier_reads_closure_checks
_snapshot_fail
grep -q "## Closure Checks" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_closure_checks_section_name: '## Closure Checks' referenced in agent" "0" "$?"
assert_pass_if_clean "test_verifier_closure_checks_section_name"

# test_verifier_backward_compat_rule: backward-compat: absence of section = pass
echo "--- test_verifier_backward_compat_rule ---"
_snapshot_fail
grep -qiE "backward|backward-compat" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_backward_compat_rule: 'backward' compat rule documented in agent" "0" "$?"
assert_pass_if_clean "test_verifier_backward_compat_rule"

# test_verifier_absent_section_pass_rule: section absence must be documented as pass (not fail)
echo "--- test_verifier_absent_section_pass_rule ---"
_snapshot_fail
grep -qiE "(no section|absent|missing|empty).*(pass|trivially|skip)" "$VERIFIER_AGENT" 2>/dev/null || \
  grep -qiE "(pass|trivially|skip).*(no section|absent|missing|empty)" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_absent_section_pass_rule: absence-equals-pass rule documented in agent" "0" "$?"
assert_pass_if_clean "test_verifier_absent_section_pass_rule"

# test_verifier_step_25_closure_checks_reading: agent must have Step 2.5 or equivalent for Closure Checks reading
echo "--- test_verifier_step_25_closure_checks_reading ---"
_snapshot_fail
grep -qE "Step 2\.5|2\.5:" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_step_25_closure_checks_reading: 'Step 2.5' (Closure Checks reading) in agent" "0" "$?"
assert_pass_if_clean "test_verifier_step_25_closure_checks_reading"

# test_verifier_one_shot_evaluation: Closure Checks evaluated one-shot (not persistent)
echo "--- test_verifier_one_shot_evaluation ---"
_snapshot_fail
grep -qiE "one.shot|one shot" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_one_shot_evaluation: 'one-shot' evaluation documented in agent" "0" "$?"
assert_pass_if_clean "test_verifier_one_shot_evaluation"

# ============================================================
print_summary
