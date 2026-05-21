#!/usr/bin/env bash
# tests/scripts/test-infer-detected-by.sh
# test_script_is_executable is intentionally RED until implementation task lands — expected TDD RED state
set -uo pipefail

PASS=0; FAIL=0

run_test() {
  local name="$1"; shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name"; ((FAIL++)) || true
  fi
}

test_mutation_auto_bug_maps_to_tests() {
  [ "$(env -i DSO_FILING_CONTEXT=mutation-auto-bug bash plugins/dso/scripts/infer-detected-by.sh 2>/dev/null)" = "tests" ]
}

test_fix_bug_phase_g_maps_to_review_llm() {
  [ "$(env -i DSO_FILING_CONTEXT=fix-bug-phase-g bash plugins/dso/scripts/infer-detected-by.sh 2>/dev/null)" = "review-llm" ]
}

test_debug_everything_maps_to_review_llm() {
  [ "$(env -i DSO_FILING_CONTEXT=debug-everything bash plugins/dso/scripts/infer-detected-by.sh 2>/dev/null)" = "review-llm" ]
}

test_review_human_maps_to_review_human() {
  [ "$(env -i DSO_FILING_CONTEXT=review-human bash plugins/dso/scripts/infer-detected-by.sh 2>/dev/null)" = "review-human" ]
}

test_production_maps_to_production() {
  [ "$(env -i DSO_FILING_CONTEXT=production bash plugins/dso/scripts/infer-detected-by.sh 2>/dev/null)" = "production" ]
}

test_user_report_maps_to_user_report() {
  [ "$(env -i DSO_FILING_CONTEXT=user-report bash plugins/dso/scripts/infer-detected-by.sh 2>/dev/null)" = "user-report" ]
}

test_internal_dogfood_maps_to_internal_dogfood() {
  [ "$(env -i DSO_FILING_CONTEXT=internal-dogfood bash plugins/dso/scripts/infer-detected-by.sh 2>/dev/null)" = "internal-dogfood" ]
}

test_empty_context_maps_to_other() {
  [ "$(env -i bash plugins/dso/scripts/infer-detected-by.sh 2>/dev/null)" = "other" ]
}

test_unknown_context_maps_to_other() {
  [ "$(env -i DSO_FILING_CONTEXT=garbage bash plugins/dso/scripts/infer-detected-by.sh 2>/dev/null)" = "other" ]
}

test_script_is_executable() {
  test -x plugins/dso/scripts/infer-detected-by.sh
}

run_test "test_mutation_auto_bug_maps_to_tests" test_mutation_auto_bug_maps_to_tests
run_test "test_fix_bug_phase_g_maps_to_review_llm" test_fix_bug_phase_g_maps_to_review_llm
run_test "test_debug_everything_maps_to_review_llm" test_debug_everything_maps_to_review_llm
run_test "test_review_human_maps_to_review_human" test_review_human_maps_to_review_human
run_test "test_production_maps_to_production" test_production_maps_to_production
run_test "test_user_report_maps_to_user_report" test_user_report_maps_to_user_report
run_test "test_internal_dogfood_maps_to_internal_dogfood" test_internal_dogfood_maps_to_internal_dogfood
run_test "test_empty_context_maps_to_other" test_empty_context_maps_to_other
run_test "test_unknown_context_maps_to_other" test_unknown_context_maps_to_other
run_test "test_script_is_executable" test_script_is_executable

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
