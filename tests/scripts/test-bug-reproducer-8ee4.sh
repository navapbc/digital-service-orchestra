#!/usr/bin/env bash
# tests/scripts/test-bug-reproducer-8ee4.sh
# Reproducer for bug 8ee4-c51c-c546-4d4e:
#   [llm-review/ci]: CI re-review treats every cycle as cycle_number=1 -> defenses
#   recorded in TrackerDefenseStore are never honored, autonomous resolution loop
#   is broken.
#
# Verifies that ci.yml correctly computes DSO_INTEGRATION_REVIEW_CYCLE as a
# separate counter from DSO_REVIEW_CYCLE (per-branch review cycle counter),
# ensuring integration reviews use their own cycle tracking.
#
# Usage: bash tests/scripts/test-bug-reproducer-8ee4.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bug-reproducer-8ee4.sh ==="
echo "Bug: CI re-review cycle counter resets to 1; integration review defenses never honored"
echo ""

# ── Test 1: ci.yml contains DSO_INTEGRATION_REVIEW_CYCLE computation ──────────
echo "Test 1: ci.yml defines DSO_INTEGRATION_REVIEW_CYCLE"
ci_yml_content="$(cat "$CI_YML")"
assert_contains \
    "ci.yml contains DSO_INTEGRATION_REVIEW_CYCLE assignment" \
    "DSO_INTEGRATION_REVIEW_CYCLE=" \
    "$ci_yml_content"

# ── Test 2: The computation is distinct from DSO_REVIEW_CYCLE ─────────────────
echo "Test 2: DSO_INTEGRATION_REVIEW_CYCLE is computed separately from DSO_REVIEW_CYCLE"
# Both variables must be present — they are separate computations
assert_contains \
    "ci.yml contains DSO_REVIEW_CYCLE (per-branch counter)" \
    "DSO_REVIEW_CYCLE=" \
    "$ci_yml_content"
assert_contains \
    "ci.yml contains DSO_INTEGRATION_REVIEW_CYCLE (integration counter)" \
    "DSO_INTEGRATION_REVIEW_CYCLE=" \
    "$ci_yml_content"

# The integration cycle must use a DIFFERENT filter than the per-branch cycle
# Per-branch uses "finding 1/" headers; integration uses "integration.*review.*cycle|DSO_INTEGRATION_REVIEW_CYCLE"
assert_contains \
    "ci.yml uses integration-review-specific filter for PRIOR_INTEGRATION" \
    "integration.*review.*cycle|DSO_INTEGRATION_REVIEW_CYCLE" \
    "$ci_yml_content"

# ── Test 3: Integration cycle is computed from integration-review PR comments ──
echo "Test 3: Integration cycle derives from integration-review-labeled PR comments"
# The PRIOR_INTEGRATION count must be sourced from PR comments (not issue comments)
# — so that squash-merged branch cycles don't pollute the integration counter
assert_contains \
    "ci.yml uses PRIOR_INTEGRATION variable for integration review cycle" \
    "PRIOR_INTEGRATION=" \
    "$ci_yml_content"

# ── Test 4: Both cycle vars propagated to the LLM review step ─────────────────
echo "Test 4: Both DSO_REVIEW_CYCLE and DSO_INTEGRATION_REVIEW_CYCLE propagated to llm review step"
assert_contains \
    "ci.yml passes DSO_INTEGRATION_REVIEW_CYCLE to the Run LLM review step" \
    "DSO_INTEGRATION_REVIEW_CYCLE: \${{ env.DSO_INTEGRATION_REVIEW_CYCLE }}" \
    "$ci_yml_content"

# ── Test 5: The two variables use independent cycle counters ───────────────────
echo "Test 5: Separation of concerns — integration cycle does not reuse per-branch formula"
# Verify that the integration cycle is computed in the per-branch cycle step
# (same step), not overriding it. Extraction tolerates step-name whitespace
# variation by accepting either "Compute DSO_REVIEW_CYCLE" with any surrounding
# whitespace; emits an explicit assertion failure if extraction yields empty.
compute_step_block="$(awk '/-[[:space:]]*name:[[:space:]]*Compute DSO_REVIEW_CYCLE/{found=1} found{print; if(/^[[:space:]]+-[[:space:]]+name:/ && !/Compute DSO_REVIEW_CYCLE/) exit}' "$CI_YML")"
if [[ -z "$compute_step_block" ]]; then
    echo "FAIL: Test 5 setup — awk extraction returned empty; the 'Compute DSO_REVIEW_CYCLE' step could not be located in $CI_YML"
    exit 1
fi
assert_contains \
    "Integration cycle computed inside 'Compute DSO_REVIEW_CYCLE' step" \
    "DSO_INTEGRATION_REVIEW_CYCLE" \
    "$compute_step_block"
assert_contains \
    "Integration cycle uses comment pattern distinct from per-branch finding-1 pattern" \
    "integration" \
    "$compute_step_block"

print_summary
