#!/usr/bin/env bash
# tests/hooks/test-review-workflow-deep-tier-dispatch-guidance.sh
#
# Lock in the deep-tier dispatch contract that prevents parallel sonnet specialists
# from clobbering each other's reviewer-findings.json output.
#
# Failure mode this guards against: an orchestrator dispatching the 3 sonnet specialists
# without setting FINDINGS_OUTPUT per slot. Each specialist falls through to the canonical
# reviewer-findings.json path and overwrites the previous specialist's output. The arch
# reviewer (or downstream consumers) sees only the last-written specialist's findings.
#
# Tests:
#   1. REVIEW-WORKFLOW.md Step 4 Deep Tier dispatch section is present
#   2. REVIEW-WORKFLOW.md contains a single MUST-level directive that FINDINGS_OUTPUT
#      is required for every specialist slot
#   3. REVIEW-WORKFLOW.md documents the 3 slot paths (reviewer-findings-{a,b,c}.json)
#   4. REVIEW-WORKFLOW.md states the failure mode (clobber) explicitly so the
#      directive is not interpretable as optional
#
# Per behavioral-testing-standard Rule 5: this is a structural-contract test on an
# instruction file. It asserts required structural markers and signal phrases, not
# arbitrary prose that could be reworded.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKFLOW_MD="${REPO_ROOT}/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

source "${REPO_ROOT}/tests/lib/assert.sh"

echo "=== test-review-workflow-deep-tier-dispatch-guidance.sh ==="

# ── Test 1: Deep Tier dispatch section exists ────────────────────────────────
echo "--- test_deep_tier_section_present ---"
if grep -qE "^### Deep Tier:.*Parallel Sonnet Dispatch" "$WORKFLOW_MD"; then
    assert_eq "deep_tier_section_present" "found" "found"
else
    assert_eq "deep_tier_section_present" "found" "missing"
fi

# ── Test 2: MUST-level FINDINGS_OUTPUT directive present ─────────────────────
# The directive must use a strong MUST-style clause naming FINDINGS_OUTPUT explicitly.
# This is the regression guard against my earlier dispatch that omitted FINDINGS_OUTPUT.
echo "--- test_findings_output_must_directive ---"
if grep -qE "MUST.*FINDINGS_OUTPUT|FINDINGS_OUTPUT.*MUST" "$WORKFLOW_MD"; then
    assert_eq "findings_output_must_directive" "found" "found"
else
    assert_eq "findings_output_must_directive" "found" "missing"
fi

# ── Test 3: All 3 slot paths documented ──────────────────────────────────────
# Per-slot filenames are the contract. If any slot is missing, parallel specialists
# will collide.
echo "--- test_three_slot_paths_documented ---"
SLOT_A_FOUND="missing"
SLOT_B_FOUND="missing"
SLOT_C_FOUND="missing"
grep -q "reviewer-findings-a\.json" "$WORKFLOW_MD" && SLOT_A_FOUND="found"
grep -q "reviewer-findings-b\.json" "$WORKFLOW_MD" && SLOT_B_FOUND="found"
grep -q "reviewer-findings-c\.json" "$WORKFLOW_MD" && SLOT_C_FOUND="found"
assert_eq "slot_a_path_documented" "found" "$SLOT_A_FOUND"
assert_eq "slot_b_path_documented" "found" "$SLOT_B_FOUND"
assert_eq "slot_c_path_documented" "found" "$SLOT_C_FOUND"

# ── Test 4: Failure mode (clobber) is explicit ───────────────────────────────
# The directive's why-it-matters must be stated so an agent reading the guidance
# cannot interpret FINDINGS_OUTPUT as a polish-level optional.
echo "--- test_clobber_failure_mode_documented ---"
if grep -qiE "clobber|overwrit(e|ing)" "$WORKFLOW_MD"; then
    assert_eq "clobber_failure_mode_documented" "found" "found"
else
    assert_eq "clobber_failure_mode_documented" "found" "missing"
fi

# ── Test 5: Step 4 mandates overlay agents in the same parallel batch ────────
# Overlay agents (test-quality, security, performance) must launch in the same
# parallel Agent dispatch as the tier reviewer, not deferred to a Step 4b
# follow-up. This guards against the orchestrator skipping Step 4b entirely
# (the bug that motivated Option 1 in cycle 2).
echo "--- test_step_4_mandates_overlay_in_parallel_batch ---"
SECTION="step_4_overlay_directive"
# Required: explicit "parallel batch" or "same batch" language tied to overlay dispatch.
if grep -qE "Single parallel batch|same parallel batch|same.{0,30}batch.*overlay|parallel batch.*overlay|overlay.*parallel batch" "$WORKFLOW_MD"; then
    OVERLAY_PARALLEL_FOUND="found"
else
    OVERLAY_PARALLEL_FOUND="missing"
fi
assert_eq "test_step_4_mandates_overlay_in_parallel_batch: Step 4 names overlay+tier as a single parallel batch" "found" "$OVERLAY_PARALLEL_FOUND"

# Required: explicit instruction to read overlay flags BEFORE dispatch (so the
# decision is made in Step 4, not deferred to Step 4b).
echo "--- test_step_4_reads_overlay_flags_before_dispatch ---"
if grep -qE "(Read|read).{0,40}overlay flags.{0,80}(before|BEFORE)|overlay flags.{0,40}(before|BEFORE).{0,40}dispatch|BEFORE building the dispatch" "$WORKFLOW_MD"; then
    READ_BEFORE_FOUND="found"
else
    READ_BEFORE_FOUND="missing"
fi
assert_eq "test_step_4_reads_overlay_flags_before_dispatch: Step 4 instructs reading overlay flags before dispatch" "found" "$READ_BEFORE_FOUND"

print_summary
