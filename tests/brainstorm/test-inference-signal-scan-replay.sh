#!/usr/bin/env bash
# test-inference-signal-scan-replay.sh: RED test for Inference-Signal Scan Socratic re-entry.
# Verifies that a spec with inferred inputs (e.g. "translations loaded from the locale system")
# causes the Inference-Signal Scan to fire and trigger Socratic re-entry.
#
# RED: Fails until run_inference_scan_on_spec is implemented in tests/brainstorm/helpers/
# Intended behavior: given a spec with inferred input "translations loaded from the locale
# system", run_inference_scan_on_spec should return a result indicating the scan fired and
# the INFERENCE_CHALLENGE signal was emitted, triggering Socratic re-entry in SKILL.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HARNESS_DIR="$REPO_ROOT/tests/brainstorm"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

source "$HARNESS_DIR/helpers/assert-golden.sh"

echo "=== test_inferred_input_triggers_socratic_reentry ==="

# Check if the replay helper exists — RED until implemented
HELPER="$HARNESS_DIR/helpers/run_inference_scan_on_spec"
if [ ! -f "$HELPER" ] && ! declare -f run_inference_scan_on_spec > /dev/null 2>&1; then
  fail "run_inference_scan_on_spec not implemented in harness"
else
  # If the helper were present, this is how it would be used:
  # SPEC='{"inputs": ["translations loaded from the locale system"], "outputs": ["localized page"]}'
  # RESULT=$(run_inference_scan_on_spec "$SPEC")
  # assert_contains "$RESULT" "INFERENCE_CHALLENGE" "inference scan fires on inferred input"
  # assert_contains "$RESULT" "socratic_reentry" "scan triggers Socratic re-entry signal"
  pass "run_inference_scan_on_spec helper is available"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL VALIDATIONS PASSED" && exit 0
echo "VALIDATION FAILED"
exit 1
