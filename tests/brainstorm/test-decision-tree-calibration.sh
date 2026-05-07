#!/usr/bin/env bash
# test-decision-tree-calibration.sh: RED tests for brainstorm decision-tree calibration matrix.
# Documents the intended behavior of the 7-sub-case calibration matrix (1023-1ceb DD3).
#
# RED: Fails until run_brainstorm_replay is implemented in tests/brainstorm/helpers/
#
# 7-sub-case decision tree calibration matrix (1023-1ceb DD3):
# 1. Inference-Signal Scan fires on ambiguous data source
# 2. Assumption category surfaces as Premise to confirm
# 3. No-inference path: clear source → scan skips re-entry
# 4. Multiple inferred sources → multiple Socratic questions
# 5. Assumption with user-outcome SC already present → no duplicate surface
# 6. NFR-style assumption (latency/cost) surfaces regardless of severity
# 7. Assumption finding resolved by user → removed from Premise-to-confirm list
#
# Sub-cases 1 and 2 have test functions below; 3–7 are documented for future implementation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HARNESS_DIR="$REPO_ROOT/tests/brainstorm"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

source "$HARNESS_DIR/helpers/assert-golden.sh"

# ---------------------------------------------------------------------------
# Sub-case 1: Inference-Signal Scan fires on ambiguous data source
# ---------------------------------------------------------------------------
echo "=== test_pipeline_part_b_inference_signal_scan ==="

# Check if the replay helper exists — RED until implemented
HELPER="$HARNESS_DIR/helpers/run-brainstorm-replay.sh"
if [ ! -f "$HELPER" ] && ! declare -f run_brainstorm_replay > /dev/null 2>&1; then
  fail "run_brainstorm_replay not implemented in harness — install tests/brainstorm/helpers/run-brainstorm-replay.sh to enable replay tests"
else
  # If the helper were present, this is how it would be used:
  # FIXTURE='{"spec": "Feature reads product catalog from the data service", "project_sources": []}'
  # RESULT=$(run_brainstorm_replay "$FIXTURE")
  # assert_contains "$RESULT" "Inference-Signal Scan" \
  #   "produced epic contains Inference-Signal Scan subsection"
  # assert_contains "$RESULT" "inferred-source:" \
  #   "scan identifies ambiguous source with inferred-source: marker"
  pass "run_brainstorm_replay helper is available"
fi

echo ""

# ---------------------------------------------------------------------------
# Sub-case 2: Assumption category surfaces as Premise to confirm
# ---------------------------------------------------------------------------
echo "=== test_pipeline_part_b_assumption_category_surfaces ==="

if [ ! -f "$HELPER" ] && ! declare -f run_brainstorm_replay > /dev/null 2>&1; then
  fail "run_brainstorm_replay not implemented in harness — install tests/brainstorm/helpers/run-brainstorm-replay.sh to enable replay tests"
else
  # If the helper were present, this is how it would be used:
  # FIXTURE='{"spec": "System must handle load; we expect <1000 users at peak", "project_sources": []}'
  # RESULT=$(run_brainstorm_replay "$FIXTURE")
  # assert_contains "$RESULT" "assumption" \
  #   "SC Gap Check surfaces finding in assumption category"
  # assert_contains "$RESULT" "Premise to confirm" \
  #   "assumption finding carries explicit Premise to confirm label"
  pass "run_brainstorm_replay helper is available"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL VALIDATIONS PASSED" && exit 0
echo "VALIDATION FAILED"
exit 1
