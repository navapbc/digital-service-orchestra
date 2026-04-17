#!/usr/bin/env bash
# test-config-ref-huge-threshold.sh — structural boundary tests for threshold documentation
# All 4 tests RED until CONFIGURATION-REFERENCE.md and dso-config.example.conf are updated

PASS=0; FAIL=0

run_test() {
  local desc="$1"; local cmd="$2"
  if eval "$cmd" 2>/dev/null; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"; ((FAIL++))
  fi
}

test_config_ref_has_huge_threshold_section() {
  run_test "test_config_ref_has_huge_threshold_section" \
    "grep -q 'review\.huge_diff_file_threshold' plugins/dso/docs/CONFIGURATION-REFERENCE.md"
}
test_config_ref_huge_threshold_default_20() {
  run_test "test_config_ref_huge_threshold_default_20" \
    "grep -A15 'huge_diff_file_threshold' plugins/dso/docs/CONFIGURATION-REFERENCE.md | grep -q '20'"
}
test_config_ref_huge_threshold_positive_integers() {
  run_test "test_config_ref_huge_threshold_positive_integers" \
    "grep -A15 'huge_diff_file_threshold' plugins/dso/docs/CONFIGURATION-REFERENCE.md | grep -qi 'positive integer'"
}
test_example_conf_has_huge_threshold_entry() {
  run_test "test_example_conf_has_huge_threshold_entry" \
    "grep -q 'huge_diff_file_threshold=20' plugins/dso/docs/dso-config.example.conf"
}

test_config_ref_has_huge_threshold_section
test_config_ref_huge_threshold_default_20
test_config_ref_huge_threshold_positive_integers
test_example_conf_has_huge_threshold_entry

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL"
  exit 1
fi
echo "PASSED: $PASS"
exit 0
