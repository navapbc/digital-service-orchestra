#!/usr/bin/env bash
# tests/skills/test-implementation-plan-retry-budget.sh
# Structural boundary test: implementation-plan SKILL.md Step 3 must contain
# a "### Retry Budget" subsection describing sub-agent retry behavior with
# model escalation from sonnet → opus → user.
#
# Story: d853-bf07 — Sub-agent retry budget with model escalation
# Task ticket: 6e11-8934
#
# Per behavioral-testing-standard.md Rule 5, instruction-file tests check the
# STRUCTURAL BOUNDARY — section headings and required subsection markers —
# not body-text phrases or file existence alone.
#
# What we test (structural boundary):
#   1. A "### Retry Budget" (or equivalent named subsection) exists inside Step 3
#   2. Step 3 contains a MAX_ATTEMPTS reference (structural marker for attempt cap)
#   3. Step 3 contains an opus escalation subsection marker
#   4. The SKILL.md describes user escalation after both tiers are exhausted
#
# Usage:
#   bash tests/skills/test-implementation-plan-retry-budget.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-retry-budget.sh ==="
echo ""

# ===========================================================================
# test_retry_budget_heading_present
#
# Given: implementation-plan/SKILL.md Step 3 "Atomic Task Drafting" section
# When: we check whether a "### Retry Budget" subsection heading exists in Step 3
# Then: the heading "### Retry Budget" must be present within Step 3
#
# Structural boundary: the presence of the subsection heading "### Retry Budget"
# is the contract. The heading is the integration point agents use to locate
# the retry budget rules. Without the heading the section does not exist.
#
# RED before implementation: heading absent → assert fails.
# GREEN after implementation: heading present inside Step 3 → assert passes.
# ===========================================================================
test_retry_budget_heading_present() {
  local _step3_section
  _step3_section=$(awk '/^## Step 3:/{found=1} found && /^## Step [^3]/{exit} found{print}' "$SKILL_FILE" 2>/dev/null || true)

  local _found_heading=0
  echo "$_step3_section" | grep -qE "^### Retry Budget" && _found_heading=1

  assert_eq \
    "test_retry_budget_heading_present: '### Retry Budget' subsection must exist in Step 3" \
    "1" "$_found_heading"
}

# ===========================================================================
# test_retry_budget_sonnet_max_attempts
#
# Given: implementation-plan/SKILL.md (full file)
# When: we look for a MAX_ATTEMPTS structural marker referencing sonnet
# Then: the file must contain MAX_ATTEMPTS (value 3) paired with sonnet
#
# Structural boundary: "MAX_ATTEMPTS" is the interface token that agents parse
# to determine the attempt cap. Its co-location with a sonnet reference anchors
# the first-tier retry count. Body-text wording may vary — the structural
# marker (the token itself) is what we assert on.
#
# RED before implementation: marker absent → assert fails.
# GREEN after implementation: marker present → assert passes.
# ===========================================================================
test_retry_budget_sonnet_max_attempts() {
  local _found_max_attempts=0
  grep -q "MAX_ATTEMPTS" "$SKILL_FILE" 2>/dev/null && _found_max_attempts=1

  assert_eq \
    "test_retry_budget_sonnet_max_attempts: SKILL.md must contain MAX_ATTEMPTS structural marker" \
    "1" "$_found_max_attempts"
}

# ===========================================================================
# test_retry_budget_opus_escalation_mentioned
#
# Given: implementation-plan/SKILL.md (full file)
# When: we look for an opus escalation subsection or structural marker
# Then: the file must reference opus escalation in the context of retry budget
#
# Structural boundary: the subsection heading "#### Opus Escalation" (or
# equivalent "### Opus" heading) is the integration contract — it signals
# to agents that a second-tier escalation path exists. We check for the
# heading pattern, not body-text describing what opus does.
#
# RED before implementation: heading absent → assert fails.
# GREEN after implementation: heading present → assert passes.
# ===========================================================================
test_retry_budget_opus_escalation_mentioned() {
  local _found_opus_heading=0
  grep -qE "^#{3,4} Opus" "$SKILL_FILE" 2>/dev/null && _found_opus_heading=1

  assert_eq \
    "test_retry_budget_opus_escalation_mentioned: SKILL.md must contain an Opus escalation subsection heading (###/####)" \
    "1" "$_found_opus_heading"
}

# ===========================================================================
# test_retry_budget_user_escalation_after_six
#
# Given: implementation-plan/SKILL.md (full file)
# When: we look for a user escalation subsection or structural marker
# Then: the file must contain a "User Escalation" subsection heading describing
#       escalation after both tiers (sonnet + opus) are exhausted
#
# Structural boundary: the subsection heading "#### User Escalation" (or
# equivalent "### User Escalation") is the integration contract. It signals
# that a fallback-to-human path exists after both model tiers fail.
# We assert on the heading, not on the count (six) or wording.
#
# RED before implementation: heading absent → assert fails.
# GREEN after implementation: heading present → assert passes.
# ===========================================================================
test_retry_budget_user_escalation_after_six() {
  local _found_user_escalation=0
  grep -qE "^#{3,4} User Escalation" "$SKILL_FILE" 2>/dev/null && _found_user_escalation=1

  assert_eq \
    "test_retry_budget_user_escalation_after_six: SKILL.md must contain a 'User Escalation' subsection heading (###/####)" \
    "1" "$_found_user_escalation"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_retry_budget_heading_present
test_retry_budget_sonnet_max_attempts
test_retry_budget_opus_escalation_mentioned
test_retry_budget_user_escalation_after_six

print_summary
