#!/usr/bin/env bash
# test-review-workflow-huge.sh — structural boundary tests for REVIEW-WORKFLOW-HUGE.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

run_test() {
  local desc="$1"; local cmd="$2"
  if eval "$cmd" 2>/dev/null; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"; ((FAIL++))
  fi
}

# ── Original structural tests (workflow scaffold) ────────────────────────────

test_huge_workflow_has_sampling_step() {
  run_test "test_huge_workflow_has_sampling_step" \
    "grep -q 'review-sample-files.sh' \"$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md\""
}
test_huge_workflow_has_consensus_section() {
  run_test "test_huge_workflow_has_consensus_section" \
    "grep -qE '^## (Step 3|Consensus)' \"$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md\""
}
test_huge_workflow_has_routing_section() {
  run_test "test_huge_workflow_has_routing_section" \
    "grep -qE '^## (Step 4|Route)' \"$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md\""
}
test_huge_workflow_has_record_review_shim_compliance() {
  run_test "test_huge_workflow_has_record_review_shim_compliance" \
    "grep -q 'CLAUDE_PLUGIN_ROOT.*record-review.sh\|record-review.sh.*CLAUDE_PLUGIN_ROOT' \"$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md\""
}
test_huge_workflow_references_pattern_extraction_contract() {
  run_test "test_huge_workflow_references_pattern_extraction_contract" \
    "grep -q 'huge-diff-pattern-extraction.md' \"$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md\" && test -f \"$REPO_ROOT/plugins/dso/docs/contracts/huge-diff-pattern-extraction.md\""
}
test_huge_workflow_record_review_has_required_flags() {
  run_test "test_huge_workflow_record_review_has_required_flags" \
    "grep -qE -- '--expected-hash|--reviewer-hash' \"$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md\""
}

# ── Fallback agent tests (RED until cf76-7091 T2/T3 complete) ────────────────

test_huge_fallback_emits_model_override() {
    _snapshot_fail
    local actual
    grep -q 'MODEL_OVERRIDE' "$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md" \
        && actual="present" || actual="absent"
    assert_eq "test_huge_fallback_emits_model_override" "present" "$actual"
    assert_pass_if_clean "test_huge_fallback_emits_model_override"
}

test_huge_fallback_references_light_agent() {
    _snapshot_fail
    local actual
    grep -q 'huge-diff-reviewer-light' "$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md" \
        && actual="present" || actual="absent"
    assert_eq "test_huge_fallback_references_light_agent" "present" "$actual"
    assert_pass_if_clean "test_huge_fallback_references_light_agent"
}

test_huge_fallback_references_standard_agent() {
    _snapshot_fail
    local actual
    grep -q 'huge-diff-reviewer-standard' "$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md" \
        && actual="present" || actual="absent"
    assert_eq "test_huge_fallback_references_standard_agent" "present" "$actual"
    assert_pass_if_clean "test_huge_fallback_references_standard_agent"
}

test_huge_fallback_references_deep_arch_agent() {
    _snapshot_fail
    local actual
    grep -q 'code-reviewer-deep-arch' "$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md" \
        && actual="present" || actual="absent"
    assert_eq "test_huge_fallback_references_deep_arch_agent" "present" "$actual"
    assert_pass_if_clean "test_huge_fallback_references_deep_arch_agent"
}

test_light_fallback_agent_model_is_opus() {
    _snapshot_fail
    local actual
    grep -q 'model: opus' "$REPO_ROOT/plugins/dso/agents/huge-diff-reviewer-light.md" \
        && actual="opus" || actual="other"
    assert_eq "test_light_fallback_agent_model_is_opus" "opus" "$actual"
    assert_pass_if_clean "test_light_fallback_agent_model_is_opus"
}

test_standard_fallback_agent_model_is_opus() {
    _snapshot_fail
    local actual
    grep -q 'model: opus' "$REPO_ROOT/plugins/dso/agents/huge-diff-reviewer-standard.md" \
        && actual="opus" || actual="other"
    assert_eq "test_standard_fallback_agent_model_is_opus" "opus" "$actual"
    assert_pass_if_clean "test_standard_fallback_agent_model_is_opus"
}

# ── Confirmed-refactor / batch-groups / anomaly tests (RED until efe7-7f1d T4/T5) ──

test_huge_confirmed_haiku_batch_references_batch_groups() {
    _snapshot_fail
    local actual
    grep -q 'review-batch-groups' "$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md" \
        && actual="present" || actual="absent"
    assert_eq "test_huge_confirmed_haiku_batch_references_batch_groups" "present" "$actual"
    assert_pass_if_clean "test_huge_confirmed_haiku_batch_references_batch_groups"
}

test_huge_confirmed_references_anomaly_agent() {
    _snapshot_fail
    local actual
    grep -q 'huge-diff-refactor-anomaly' "$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md" \
        && actual="present" || actual="absent"
    assert_eq "test_huge_confirmed_references_anomaly_agent" "present" "$actual"
    assert_pass_if_clean "test_huge_confirmed_references_anomaly_agent"
}

test_refactor_anomaly_agent_exists_and_is_opus() {
    _snapshot_fail
    local file_actual model_actual
    [ -f "$REPO_ROOT/plugins/dso/agents/huge-diff-refactor-anomaly.md" ] \
        && file_actual="exists" || file_actual="missing"
    grep -q 'model: opus' "$REPO_ROOT/plugins/dso/agents/huge-diff-refactor-anomaly.md" 2>/dev/null \
        && model_actual="opus" || model_actual="other"
    assert_eq "test_refactor_anomaly_agent_exists_and_is_opus_file" "exists" "$file_actual"
    assert_eq "test_refactor_anomaly_agent_exists_and_is_opus_model" "opus" "$model_actual"
    assert_pass_if_clean "test_refactor_anomaly_agent_exists_and_is_opus"
}

test_refactor_anomaly_agent_has_dimension_labels() {
    _snapshot_fail
    local actual
    grep -qE 'pattern_conformance|behavioral_drift' \
        "$REPO_ROOT/plugins/dso/agents/huge-diff-refactor-anomaly.md" 2>/dev/null \
        && actual="present" || actual="absent"
    assert_eq "test_refactor_anomaly_agent_has_dimension_labels" "present" "$actual"
    assert_pass_if_clean "test_refactor_anomaly_agent_has_dimension_labels"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_huge_workflow_has_sampling_step
test_huge_workflow_has_consensus_section
test_huge_workflow_has_routing_section
test_huge_workflow_has_record_review_shim_compliance
test_huge_workflow_references_pattern_extraction_contract
test_huge_workflow_record_review_has_required_flags

echo ""
test_huge_fallback_emits_model_override
echo ""
test_huge_fallback_references_light_agent
echo ""
test_huge_fallback_references_standard_agent
echo ""
test_huge_fallback_references_deep_arch_agent
echo ""
test_light_fallback_agent_model_is_opus
echo ""
test_standard_fallback_agent_model_is_opus
echo ""
test_huge_confirmed_haiku_batch_references_batch_groups
echo ""
test_huge_confirmed_references_anomaly_agent
echo ""
test_refactor_anomaly_agent_exists_and_is_opus
echo ""
test_refactor_anomaly_agent_has_dimension_labels
echo ""

print_summary
