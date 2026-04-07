#!/usr/bin/env bash
# Structural validation for planning-intelligence log mechanism-field extensions in brainstorm SKILL.md.
#
# Why source-grepping is used here (precedent and rationale):
#   SKILL.md is a non-executable instruction document — its text content IS the behavioral
#   contract for agents. The agent reads these instructions and acts on them; there is no
#   runnable code to invoke. Source-grepping SKILL.md is the established testing pattern for
#   agent instruction files in this codebase (see tests/skills/test-brainstorm-approval-gate.sh,
#   test-follow-on-scrutiny.sh, test-brainstorm-scenario-analysis.sh — all follow this same
#   pattern). The test quality gate's bash-grep detector does not flag .md file grepping
#   because the contract lives in the document content.
#
# Tests (all RED against current SKILL.md lines 416-423 — the log only contains web research,
# scenario analysis, and practitioner cycles; the three mechanism fields do not exist yet):
#   - test_log_follow_on_scrutiny_field
#   - test_log_feasibility_resolution_field
#   - test_log_llm_instruction_signal_field
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract the planning-intelligence log section from SKILL.md using python3 (BSD sed compat).
# Returns content from the Planning Intelligence Log heading through to the next heading.
_extract_log_section() {
  python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Match from the Planning Intelligence Log heading through to the next heading of same or higher level
match = re.search(
    r'(?im)(### Planning Intelligence Log.*?)(?=^###|^##\s|\Z)',
    content,
    re.DOTALL
)
if match:
    print(match.group(1))
EOF
}

_log_section=$(_extract_log_section) || true

# ---------------------------------------------------------------------------
# Test 1: planning-intelligence log contains follow_on_scrutiny_depth field
# ---------------------------------------------------------------------------
test_log_follow_on_scrutiny_field() {
  echo ""
  echo "=== test_log_follow_on_scrutiny_field ==="

  # The planning-intelligence log must record follow-on scrutiny depth
  # via a field referencing follow_on_scrutiny_depth (ran + depth).
  # Given: SKILL.md planning-intelligence log section
  # When: the log section is read
  # Then: it contains a follow-on scrutiny field referencing follow_on_scrutiny_depth

  if grep -qi "follow_on_scrutiny_depth" <<< "$_log_section"; then
    pass "planning-intelligence log contains follow_on_scrutiny_depth field"
  else
    fail "planning-intelligence log missing follow_on_scrutiny_depth field (log must record whether follow-on scrutiny ran and at what depth)"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: planning-intelligence log contains feasibility_cycle_count field
# ---------------------------------------------------------------------------
test_log_feasibility_resolution_field() {
  echo ""
  echo "=== test_log_feasibility_resolution_field ==="

  # The planning-intelligence log must record feasibility resolution cycle count
  # and triggering gap via a field referencing feasibility_cycle_count.
  # Given: SKILL.md planning-intelligence log section
  # When: the log section is read
  # Then: it contains a feasibility-resolution field referencing feasibility_cycle_count

  if grep -qi "feasibility_cycle_count" <<< "$_log_section"; then
    pass "planning-intelligence log contains feasibility_cycle_count field"
  else
    fail "planning-intelligence log missing feasibility_cycle_count field (log must record feasibility resolution cycle count and triggering gap)"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: planning-intelligence log contains matched_keyword field
# ---------------------------------------------------------------------------
test_log_llm_instruction_signal_field() {
  echo ""
  echo "=== test_log_llm_instruction_signal_field ==="

  # The planning-intelligence log must record LLM-instruction signal state
  # (whether it fired and the matched keyword) via a field referencing matched_keyword.
  # Given: SKILL.md planning-intelligence log section
  # When: the log section is read
  # Then: it contains an LLM-instruction signal field referencing matched_keyword

  if grep -qi "matched_keyword" <<< "$_log_section"; then
    pass "planning-intelligence log contains matched_keyword field"
  else
    fail "planning-intelligence log missing matched_keyword field (log must record LLM-instruction signal fired state and matched keyword)"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_log_follow_on_scrutiny_field
test_log_feasibility_resolution_field
test_log_llm_instruction_signal_field

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "VALIDATION FAILED"
  exit 1
fi

echo "ALL VALIDATIONS PASSED"
exit 0
