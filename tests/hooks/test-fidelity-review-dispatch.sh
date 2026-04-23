#!/usr/bin/env bash
# tests/hooks/test-fidelity-review-dispatch.sh
#
# Structural boundary test: epic-scrutiny-pipeline.md Step 4 must prohibit
# combining multiple reviewer prompts into a single agent call.
#
# Rule 5 compliance: tests the structural contract of an instruction file —
# the PROHIBITED directive is the behavioral interface that forces the
# orchestrator to dispatch reviewers as independent agents.
#
# Fixes ticket 17f7-9af1: orchestrator dispatched a single sub-agent for all
# 3 fidelity review perspectives instead of 3 separate agents in parallel.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PIPELINE_MD="${REPO_ROOT}/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"

# Source shared assert library
# shellcheck source=tests/lib/assert.sh
source "${REPO_ROOT}/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# test_step4_prohibits_merged_reviewer_dispatch
#
# Given: Step 4 Fidelity Review section exists in epic-scrutiny-pipeline.md
# When:  The Step 4 section text is extracted
# Then:  The section contains a PROHIBITED directive against merging reviewers
#        into a single agent call
# ---------------------------------------------------------------------------
test_step4_prohibits_merged_reviewer_dispatch() {
  if [ ! -f "$PIPELINE_MD" ]; then
    assert_eq "pipeline file must exist" "exists" "missing"
    return
  fi

  # Extract the Step 4 section: lines from "## Step 4" up to the next "## Step"
  local step4_text
  step4_text="$(awk '
    /^## Step 4/ { in_section=1 }
    in_section && /^## Step [^4]/ { in_section=0 }
    in_section { print }
  ' "$PIPELINE_MD")"

  if [ -z "$step4_text" ]; then
    assert_eq "Step 4 section must be present in pipeline" "non-empty" "empty"
    return
  fi

  # Assert that Step 4 contains a PROHIBITED directive (case-sensitive)
  local has_prohibited=false
  if echo "$step4_text" | grep -q "PROHIBITED"; then
    has_prohibited=true
  fi

  assert_eq \
    "Step 4 must contain a PROHIBITED directive against merged reviewer dispatch" \
    "true" \
    "$has_prohibited"
}

# ---------------------------------------------------------------------------
# test_step4_requires_separate_agent_calls
#
# Given: Step 4 section exists
# When:  The section text is extracted
# Then:  The section requires dispatching reviewers as separate independent
#        agents (keyword: "independent" or "separate" near "Agent")
# ---------------------------------------------------------------------------
test_step4_requires_separate_agent_calls() {
  if [ ! -f "$PIPELINE_MD" ]; then
    assert_eq "pipeline file must exist" "exists" "missing"
    return
  fi

  local step4_text
  step4_text="$(awk '
    /^## Step 4/ { in_section=1 }
    in_section && /^## Step [^4]/ { in_section=0 }
    in_section { print }
  ' "$PIPELINE_MD")"

  if [ -z "$step4_text" ]; then
    assert_eq "Step 4 section must be present in pipeline" "non-empty" "empty"
    return
  fi

  # Assert that Step 4 uses language emphasizing separate/independent agents
  local has_independent=false
  if echo "$step4_text" | grep -qiE "separate.*[Aa]gent|independent.*[Aa]gent|[Aa]gent.*separate|[Aa]gent.*independent"; then
    has_independent=true
  fi

  assert_eq \
    "Step 4 must require separate independent Agent calls for each reviewer" \
    "true" \
    "$has_independent"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
test_step4_prohibits_merged_reviewer_dispatch
test_step4_requires_separate_agent_calls

print_summary
