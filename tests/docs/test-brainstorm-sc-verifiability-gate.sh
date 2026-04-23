#!/usr/bin/env bash
# tests/docs/test-brainstorm-sc-verifiability-gate.sh
#
# Architectural contract test: brainstorm/SKILL.md must include a post-deployment
# measurement SC classification procedure with a rejection/rerouting path.
#
# Contract: the SC verifiability rule must provide:
#   (1) A post-deployment measurement anti-pattern with concrete examples
#   (2) A DEFERRED_MEASUREMENT classification tag or equivalent rejection path
#
# This is a design-contract test: the prompt text IS the behavioral contract —
# its presence prevents brainstorm from generating unverifiable SCs that cause
# false failures at completion-verifier time (bug 0436-32dc).
#
# RED phase: both tests FAIL because the classification procedure does not exist.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

BRAINSTORM_SKILL="$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"

echo "=== test-brainstorm-sc-verifiability-gate.sh ==="

skill_content="$(< "$BRAINSTORM_SKILL")"

# ---------------------------------------------------------------------------
# test_deferred_measurement_classification_exists
#
# Verifies that the brainstorm SKILL.md names a classification for SCs that
# require post-deployment measurement data (telemetry, A/B results, baselines).
# The classification must have a concrete label so brainstorm can tag such SCs
# rather than silently accepting them into the verifiable SC list.
#
# Observable behavior: brainstorm will classify and tag observable-behavior SCs
# that cannot be verified at sprint close time, preventing completion-verifier
# from producing false FAIL verdicts.
# ---------------------------------------------------------------------------
echo ""
echo "Test 1: DEFERRED_MEASUREMENT classification exists in SC rules"

deferred_tag_present=false
if echo "$skill_content" | grep -q "DEFERRED_MEASUREMENT"; then
    deferred_tag_present=true
fi

assert_eq "T1: DEFERRED_MEASUREMENT classification present in brainstorm/SKILL.md" \
    "true" "$deferred_tag_present"

# ---------------------------------------------------------------------------
# test_post_deployment_examples_present
#
# Verifies that the brainstorm SKILL.md includes at least one concrete example
# of a post-deployment measurement SC (e.g., "drops ≥30% against baseline",
# "adoption rate", "time-series", "A/B test"). Examples allow the LLM to
# recognize the anti-pattern reliably rather than only having a prose rule.
#
# Observable behavior: brainstorm will recognize "workflow-restart rate drops
# ≥30% against pre-epic baseline" as a post-deployment measurement SC, not a
# verifiable sprint-session criterion.
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: post-deployment measurement examples present in SC rules"

examples_present=false
if echo "$skill_content" | grep -qE "baseline|adoption rate|A/B test|time.series|telemetry" \
   && echo "$skill_content" | grep -q "DEFERRED_MEASUREMENT"; then
    examples_present=true
fi

assert_eq "T2: post-deployment measurement examples present alongside DEFERRED_MEASUREMENT" \
    "true" "$examples_present"

# ---------------------------------------------------------------------------
print_summary
