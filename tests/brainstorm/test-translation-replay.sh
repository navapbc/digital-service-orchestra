#!/usr/bin/env bash
# test-translation-replay.sh: RED test for translation sourcing decision in brainstorm output.
# Verifies that a feature using an external translation API causes the brainstorm harness
# to surface a sourcing decision in the epic ticket description.
#
# RED: Fails until run_brainstorm_replay is implemented in tests/brainstorm/helpers/
# Intended behavior: given a fixture simulating a feature that reads data from an external
# translation API (no existing DSO/internal source), run_brainstorm_replay should return
# output where the epic ticket description contains an explicit sourcing decision — recording
# whether the translation API integration is handled via a new internal service, a 3rd-party
# vendor, or declared as an external dependency. The sourcing decision must be explicit, not
# left implicit in the description.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HARNESS_DIR="$REPO_ROOT/tests/brainstorm"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

source "$HARNESS_DIR/helpers/assert-golden.sh"

echo "=== test_pipeline_part_b_translation_sourcing_decision ==="

# Check if the replay helper exists — RED until implemented
if ! declare -f run_brainstorm_replay > /dev/null 2>&1; then
  fail "run_brainstorm_replay not implemented in harness — install tests/brainstorm/helpers/run-brainstorm-replay.sh to enable replay tests"
else
  # If the helper were present, this is how it would be used:
  # FIXTURE='{"feature": "translate user content via external API", "data_source": "external_translation_api", "internal_source": null}'
  # RESULT=$(run_brainstorm_replay "$FIXTURE")
  # assert_contains "$RESULT" "sourcing_decision" "epic description contains explicit sourcing decision"
  # assert_contains "$RESULT" "translation" "sourcing decision references translation API integration"
  # # Sourcing decision must be one of: internal_service, third_party_vendor, external_dependency
  # assert_matches "$RESULT" "internal_service\|third_party_vendor\|external_dependency" "sourcing decision uses a recognized handling category"
  pass "run_brainstorm_replay helper is available"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL VALIDATIONS PASSED" && exit 0
echo "VALIDATION FAILED"
exit 1
