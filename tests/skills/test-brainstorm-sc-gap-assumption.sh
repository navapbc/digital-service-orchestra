#!/usr/bin/env bash
# Structural tests for SC Gap Check Premise-to-confirm branch in brainstorm post-scrutiny-handlers.md.
# Tests: Premise-to-confirm branch presence, schema enum consistency (assumption), no severity filter.
# NOTE: These tests are intentionally RED — the post-scrutiny-handlers.md does not yet contain the
# "Premise to confirm" branch for assumption findings. They turn GREEN when the implementation task
# adds the SC Gap Check assumption branch to post-scrutiny-handlers.md (story 8c28-9f34).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

POST_SCRUTINY="$REPO_ROOT/plugins/dso/skills/brainstorm/phases/post-scrutiny-handlers.md"
SCENARIO_RED_TEAM="$REPO_ROOT/plugins/dso/skills/brainstorm/prompts/scenario-red-team.md"

echo "=== test_sc_gap_check_premise_to_confirm_branch ==="
SECTION="test_sc_gap_check_premise_to_confirm_branch"
# Check that the SC Gap Check section contains "Premise to confirm"
if grep -q "Premise to confirm" "$POST_SCRUTINY"; then
  pass "post-scrutiny-handlers.md contains 'Premise to confirm' in SC Gap Check"
else
  fail "post-scrutiny-handlers.md missing 'Premise to confirm' in SC Gap Check"
fi
# Check that confirm/revise/accept-risk options are present
if grep -qE "(confirm|Confirm).*(revise|Revise)" "$POST_SCRUTINY" || grep -q "accept.risk\|accept risk" "$POST_SCRUTINY"; then
  pass "SC Gap Check Premise branch contains confirm/revise/accept-risk options"
else
  fail "SC Gap Check Premise branch missing confirm/revise/accept-risk options"
fi
# Check that 'assumption' appears in the SC Gap Check context
if grep -q "assumption" "$POST_SCRUTINY"; then
  pass "post-scrutiny-handlers.md references 'assumption' category"
else
  fail "post-scrutiny-handlers.md missing 'assumption' category reference"
fi

echo ""
echo "=== test_sc_gap_assumption_schema_enum_consistent ==="
SECTION="test_sc_gap_assumption_schema_enum_consistent"
# Both emitter and consumer must reference "assumption" as the schema enum value
if grep -q '"assumption"' "$SCENARIO_RED_TEAM"; then
  pass "scenario-red-team.md (emitter) contains schema enum value \"assumption\""
else
  fail "scenario-red-team.md (emitter) missing schema enum value \"assumption\""
fi
if grep -q "assumption" "$POST_SCRUTINY"; then
  pass "post-scrutiny-handlers.md (consumer) references 'assumption' category"
else
  fail "post-scrutiny-handlers.md (consumer) missing 'assumption' category reference"
fi

echo ""
echo "=== test_sc_gap_no_severity_filter_on_assumption ==="
SECTION="test_sc_gap_no_severity_filter_on_assumption"
# The SC Gap Check assumption branch must NOT contain severity filtering
# Extract the SC Gap Check section (from ## SC Gap Check to the next ## heading)
_gap_section=$(sed -n '/^## SC Gap Check/,/^## /p' "$POST_SCRUTINY" | head -50)
if echo "$_gap_section" | grep -qE "severity.*(critical|high)|filter.*severity|(critical|high).*only"; then
  fail "SC Gap Check assumption branch contains severity filtering (low/medium findings would be excluded)"
else
  pass "SC Gap Check assumption branch has no severity filter (all assumption findings surface)"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL VALIDATIONS PASSED" && exit 0
echo "VALIDATION FAILED"
exit 1
