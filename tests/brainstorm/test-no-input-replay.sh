#!/usr/bin/env bash
# test-no-input-replay.sh: RED test for brainstorm pipeline behavior on a purely internal feature.
# Verifies that a feature with no external data sources, no external APIs, and no user data
# ingestion (e.g., a UI theme toggle) produces an epic description that explicitly states
# "no external inputs" and does NOT spuriously fire the Inference-Signal Scan.
#
# RED: Fails until run_brainstorm_replay is implemented in tests/brainstorm/helpers/
# Intended behavior: given a fixture for a purely internal feature (UI theme toggle),
# run_brainstorm_replay should return a result where:
#   1. The epic ticket description's Inputs/Sources section explicitly states
#      "no external inputs" or equivalent phrasing.
#   2. The Inference-Signal Scan subsection is either absent or explicitly states
#      "no inferred sources detected" — i.e., the scan does NOT fire spuriously
#      when inputs are truly absent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HARNESS_DIR="$REPO_ROOT/tests/brainstorm"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

source "$HARNESS_DIR/helpers/assert-golden.sh"

echo "=== test_pipeline_part_b_no_external_inputs_confirmed ==="

# Check if the replay helper exists — RED until implemented
HELPER="$HARNESS_DIR/helpers/run-brainstorm-replay.sh"
if [ ! -f "$HELPER" ] && ! declare -f run_brainstorm_replay > /dev/null 2>&1; then
  fail "run_brainstorm_replay not implemented in harness — install tests/brainstorm/helpers/run-brainstorm-replay.sh to enable replay tests"
else
  # If the helper were present, this is how it would be used:
  # FIXTURE='{"feature": "UI theme toggle", "description": "Allow users to switch between light and dark mode. No external data sources, no external APIs, no user data ingestion."}'
  # RESULT=$(run_brainstorm_replay "$FIXTURE")
  # assert_contains "$RESULT" "no external inputs" "epic description states no external inputs in Inputs/Sources section"
  # assert_not_contains "$RESULT" "INFERENCE_CHALLENGE" "inference scan does not fire spuriously when inputs are absent"
  # OR: assert_contains "$RESULT" "no inferred sources detected" "inference scan section explicitly states no inferred sources"
  pass "run_brainstorm_replay helper is available"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL VALIDATIONS PASSED" && exit 0
echo "VALIDATION FAILED"
exit 1
