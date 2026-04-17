#!/usr/bin/env bash
# test-review-workflow-huge.sh — structural boundary tests for REVIEW-WORKFLOW-HUGE.md
# All 5 tests RED until REVIEW-WORKFLOW-HUGE.md is implemented (Task 4)
# test_huge_workflow_references_pattern_extraction_contract passes GREEN immediately

PASS=0; FAIL=0

run_test() {
  local desc="$1"; local cmd="$2"
  if eval "$cmd" 2>/dev/null; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"; ((FAIL++))
  fi
}

test_huge_workflow_has_sampling_step() {
  run_test "test_huge_workflow_has_sampling_step" \
    "grep -q 'review-sample-files.sh' plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md"
}
test_huge_workflow_has_consensus_section() {
  run_test "test_huge_workflow_has_consensus_section" \
    "grep -qE '^## (Step 3|Consensus)' plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md"
}
test_huge_workflow_has_routing_section() {
  run_test "test_huge_workflow_has_routing_section" \
    "grep -qE '^## (Step 4|Route)' plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md"
}
test_huge_workflow_has_record_review_shim_compliance() {
  run_test "test_huge_workflow_has_record_review_shim_compliance" \
    "grep -q 'CLAUDE_PLUGIN_ROOT.*record-review.sh\|record-review.sh.*CLAUDE_PLUGIN_ROOT' plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md"
}
test_huge_workflow_references_pattern_extraction_contract() {
  run_test "test_huge_workflow_references_pattern_extraction_contract" \
    "grep -q 'huge-diff-pattern-extraction.md' plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md && test -f plugins/dso/docs/contracts/huge-diff-pattern-extraction.md"
}
test_huge_workflow_record_review_has_required_flags() {
  run_test "test_huge_workflow_record_review_has_required_flags" \
    "grep -qE -- '--expected-hash|--reviewer-hash' plugins/dso/docs/workflows/REVIEW-WORKFLOW-HUGE.md"
}

test_huge_workflow_has_sampling_step
test_huge_workflow_has_consensus_section
test_huge_workflow_has_routing_section
test_huge_workflow_has_record_review_shim_compliance
test_huge_workflow_references_pattern_extraction_contract
test_huge_workflow_record_review_has_required_flags

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
