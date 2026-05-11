#!/usr/bin/env bash
# tests/scripts/test-complexity-gate.sh
# Smoke tests for the shared complexity evaluator and routing logic.
#
# Usage: bash tests/scripts/test-complexity-gate.sh
# Returns: exit 0 if all non-PENDING tests pass, exit 1 otherwise
# No live LLM calls — safe to run with ANTHROPIC_API_KEY unset.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/complexity-gate"
SHARED_EVALUATOR="$DSO_PLUGIN_DIR/skills/shared/prompts/complexity-evaluator.md"
SPRINT_EVALUATOR="$DSO_PLUGIN_DIR/skills/sprint/prompts/complexity-evaluator.md"
EPIC_EVALUATOR="$DSO_PLUGIN_DIR/skills/sprint/prompts/epic-complexity-evaluator.md"
BRAINSTORM_SKILL="$DSO_PLUGIN_DIR/skills/brainstorm/SKILL.md"
PREPLANNING_SKILL="$DSO_PLUGIN_DIR/skills/preplanning/SKILL.md"

PASS=0
FAIL=0
PENDING=0

echo "=== test-complexity-gate.sh ==="
echo ""

# ── Helper: extract classification from a fixture JSON file ──────────────────
route_classification() {
  local fixture_file="$1"
  local classification
  classification=$(python3 -c "
import json, sys
data = json.load(open('$fixture_file'))
print(data['classification'])
" 2>/dev/null) || { echo "error"; return 1; }
  case "$classification" in
    TRIVIAL)  echo "pass-through" ;;
    MODERATE) echo "pass-through" ;;
    COMPLEX)  echo "epic-create" ;;
    *)        echo "unknown" ;;
  esac
}

# ── Helper: check whether a fixture is a Tier 0-1 bug (bypass evaluator) ──────
# Returns 0 (true) if type=bug AND tier<=1, else returns 1 (false/no bypass).
should_bypass() {
  local fixture_file="$1"
  python3 -c "
import json, sys
data = json.load(open('$fixture_file'))
ticket_type = data.get('type', '')
tier = data.get('tier', 999)
if ticket_type == 'bug' and tier <= 1:
    sys.exit(0)
else:
    sys.exit(1)
" 2>/dev/null
}

# ── Test case A: structural validation of shared evaluator ───────────────────
echo "Test case A: Structural validation of shared evaluator"
test_case_A_pass=true

# A1: TRIVIAL, MODERATE, COMPLEX all appear
if grep -q "TRIVIAL" "$SHARED_EVALUATOR" && grep -q "MODERATE" "$SHARED_EVALUATOR" && grep -q "COMPLEX" "$SHARED_EVALUATOR"; then
  echo "  PASS A1: TRIVIAL/MODERATE/COMPLEX threshold table present"
else
  echo "  FAIL A1: Missing TRIVIAL/MODERATE/COMPLEX in $SHARED_EVALUATOR" >&2
  test_case_A_pass=false
fi

# A2: scope_certainty section present
if grep -q "scope_certainty" "$SHARED_EVALUATOR"; then
  echo "  PASS A2: scope_certainty section present"
else
  echo "  FAIL A2: scope_certainty section missing from $SHARED_EVALUATOR" >&2
  test_case_A_pass=false
fi

# A3: Bug and Feature sub-sections in scope_certainty
if grep -q "type: bug" "$SHARED_EVALUATOR" && grep -q "type: story" "$SHARED_EVALUATOR"; then
  echo "  PASS A3: Bug and Story sub-sections present"
else
  echo "  FAIL A3: Missing 'type: bug' or 'type: story' sub-sections in $SHARED_EVALUATOR" >&2
  test_case_A_pass=false
fi

# A4: ≥2 examples per context (bug examples: Example B-; feature examples: Example F-)
bug_example_count=$(grep -c "Example B-" "$SHARED_EVALUATOR" 2>/dev/null || echo 0)
feature_example_count=$(grep -c "Example F-" "$SHARED_EVALUATOR" 2>/dev/null || echo 0)
if [ "$bug_example_count" -ge 2 ] && [ "$feature_example_count" -ge 2 ]; then
  echo "  PASS A4: ≥2 examples per context (bug: $bug_example_count, feature: $feature_example_count)"
else
  echo "  FAIL A4: Insufficient examples — bug: $bug_example_count (need ≥2), feature: $feature_example_count (need ≥2)" >&2
  test_case_A_pass=false
fi

# A5: Scoring rules table (Classification Rules section or Tier column)
_tier_found=0
grep -q "Classification Rules" "$SHARED_EVALUATOR" && _tier_found=1
[[ "$_tier_found" -eq 0 ]] && grep -q "| Tier" "$SHARED_EVALUATOR" \
    && _tier_found=1
[[ "$_tier_found" -eq 0 ]] && grep -q "| \*\*Tier\*\*\|Tier |" "$SHARED_EVALUATOR" \
    && _tier_found=1
if [[ "$_tier_found" -eq 1 ]]; then
  echo "  PASS A5: Scoring rules table present"
else
  echo "  FAIL A5: Scoring rules table (Classification Rules or Tier) missing from $SHARED_EVALUATOR" >&2
  test_case_A_pass=false
fi

# A6: JSON output schema block with both 'classification' and 'scope_certainty'
if grep -q '"classification"' "$SHARED_EVALUATOR" && grep -q '"scope_certainty"' "$SHARED_EVALUATOR"; then
  echo "  PASS A6: JSON output schema block contains classification and scope_certainty"
else
  echo "  FAIL A6: JSON schema block missing 'classification' or 'scope_certainty' in $SHARED_EVALUATOR" >&2
  test_case_A_pass=false
fi

if $test_case_A_pass; then
  echo "  → Test case A: PASS"
  (( PASS++ ))
else
  echo "  → Test case A: FAIL" >&2
  (( FAIL++ ))
fi
echo ""

# ── Test case B: fixture-based routing logic ─────────────────────────────────
echo "Test case B: Fixture-based routing logic"
test_case_B_pass=true

# B1: trivial.json → pass-through
result=$(route_classification "$FIXTURE_DIR/trivial.json")
if [ "$result" = "pass-through" ]; then
  echo "  PASS B1: TRIVIAL fixture routes to pass-through"
else
  echo "  FAIL B1: TRIVIAL fixture expected pass-through, got: $result" >&2
  test_case_B_pass=false
fi

# B2: moderate.json → pass-through
result=$(route_classification "$FIXTURE_DIR/moderate.json")
if [ "$result" = "pass-through" ]; then
  echo "  PASS B2: MODERATE fixture routes to pass-through"
else
  echo "  FAIL B2: MODERATE fixture expected pass-through, got: $result" >&2
  test_case_B_pass=false
fi

# B3: complex.json → epic-create
result=$(route_classification "$FIXTURE_DIR/complex.json")
if [ "$result" = "epic-create" ]; then
  echo "  PASS B3: COMPLEX fixture routes to epic-create"
else
  echo "  FAIL B3: COMPLEX fixture expected epic-create, got: $result" >&2
  test_case_B_pass=false
fi

if $test_case_B_pass; then
  echo "  → Test case B: PASS"
  (( PASS++ ))
else
  echo "  → Test case B: FAIL" >&2
  (( FAIL++ ))
fi
echo ""

# ── Test case C: Tier 0-1 bug bypass ─────────────────────────────────────────
echo "Test case C: Tier 0-1 bug bypass"
test_case_C_pass=true

# C1: tier01-bug.json (type=bug, tier=1) should bypass (return 0)
if should_bypass "$FIXTURE_DIR/tier01-bug.json"; then
  echo "  PASS C1: Tier 1 bug fixture triggers bypass"
else
  echo "  FAIL C1: Tier 1 bug fixture did not trigger bypass (expected bypass=true)" >&2
  test_case_C_pass=false
fi

# C2: complex.json (no type/tier fields) should NOT bypass
if should_bypass "$FIXTURE_DIR/complex.json"; then
  echo "  FAIL C2: COMPLEX fixture incorrectly triggered bypass" >&2
  test_case_C_pass=false
else
  echo "  PASS C2: COMPLEX fixture (non-bug) correctly skips bypass"
fi

if $test_case_C_pass; then
  echo "  → Test case C: PASS"
  (( PASS++ ))
else
  echo "  → Test case C: FAIL" >&2
  (( FAIL++ ))
fi
echo ""

# ── Test case D: delegation prose in sprint evaluator files ──────────────────
echo "Test case D: Delegation prose in sprint evaluator files"
test_case_D_pass=true

DELEGATION_PATTERN="Load the shared rubric dimensions from"
INLINE_THRESHOLD_PATTERN="Estimated files to modify"

# D1: sprint complexity-evaluator.md contains delegation prose
if grep -q "$DELEGATION_PATTERN" "$SPRINT_EVALUATOR"; then
  echo "  PASS D1: Sprint complexity-evaluator.md contains delegation prose"
else
  echo "  FAIL D1: Sprint complexity-evaluator.md missing delegation prose: '$DELEGATION_PATTERN'" >&2
  test_case_D_pass=false
fi

# D2: epic-complexity-evaluator.md contains delegation prose
if grep -q "$DELEGATION_PATTERN" "$EPIC_EVALUATOR"; then
  echo "  PASS D2: Epic complexity-evaluator.md contains delegation prose"
else
  echo "  FAIL D2: Epic complexity-evaluator.md missing delegation prose: '$DELEGATION_PATTERN'" >&2
  test_case_D_pass=false
fi

# D3: sprint complexity-evaluator.md does NOT define inline dimension thresholds
if grep -q "$INLINE_THRESHOLD_PATTERN" "$SPRINT_EVALUATOR"; then
  echo "  FAIL D3: Sprint complexity-evaluator.md still defines inline thresholds ('$INLINE_THRESHOLD_PATTERN' found)" >&2
  test_case_D_pass=false
else
  echo "  PASS D3: Sprint complexity-evaluator.md does not define inline thresholds"
fi

# D4: epic-complexity-evaluator.md does NOT define inline dimension thresholds
if grep -q "$INLINE_THRESHOLD_PATTERN" "$EPIC_EVALUATOR"; then
  echo "  FAIL D4: Epic complexity-evaluator.md still defines inline thresholds ('$INLINE_THRESHOLD_PATTERN' found)" >&2
  test_case_D_pass=false
else
  echo "  PASS D4: Epic complexity-evaluator.md does not define inline thresholds"
fi

if $test_case_D_pass; then
  echo "  → Test case D: PASS"
  (( PASS++ ))
else
  echo "  → Test case D: FAIL" >&2
  (( FAIL++ ))
fi
echo ""

# ── Test case E: /dso:preplanning SKILL.md Phase A Step 1.5 complexity gate ─────
echo "Test case E: /dso:preplanning SKILL.md Phase A Step 1.5 complexity gate dispatch"
# The complexity gate that classifies an epic at the start of preplanning (formerly
# the last step of brainstorm). It must dispatch the complexity evaluator agent,
# include the --lightweight routing branch (MODERATE), and contain a fallback for
# evaluator failure.

has_complexity_gate=false
if grep -q "complexity-evaluator\|complexity gate" "$PREPLANNING_SKILL" 2>/dev/null; then
  if grep -q "\-\-lightweight" "$PREPLANNING_SKILL" 2>/dev/null; then
    if grep -q "fallback\|fall through\|haiku failure" "$PREPLANNING_SKILL" 2>/dev/null; then
      has_complexity_gate=true
    fi
  fi
fi

if $has_complexity_gate; then
  echo "  PASS E1: Complexity gate dispatch found in /dso:preplanning SKILL.md"
  echo "  PASS E2: --lightweight routing branch present"
  echo "  PASS E3: Fallback prose present"
  echo "  → Test case E: PASS"
  (( PASS++ ))
else
  echo "  FAIL E: /dso:preplanning SKILL.md Phase A Step 1.5 missing complexity gate dispatch," >&2
  echo "          --lightweight routing branch, or fallback prose." >&2
  echo "  → Test case E: FAIL" >&2
  (( FAIL++ ))
fi
echo ""

# ── Test case E2: /dso:brainstorm SKILL.md must NOT dispatch the evaluator ──────
echo "Test case E2: /dso:brainstorm SKILL.md must not dispatch complexity evaluator (moved to preplanning)"
if grep -q "complexity-evaluator" "$BRAINSTORM_SKILL" 2>/dev/null; then
  echo "  FAIL E2: brainstorm SKILL.md still references complexity-evaluator — should be removed (moved to preplanning)" >&2
  (( FAIL++ ))
else
  echo "  PASS E2: brainstorm SKILL.md no longer dispatches complexity-evaluator"
  (( PASS++ ))
fi
echo ""

# ── Test function: routing table contains fix-bug entry ──────────────────────
test_routing_table_contains_fix_bug() {
  if grep -q "fix-bug post-investigation" "$SHARED_EVALUATOR"; then
    echo "  PASS F1: Context-Specific Routing table contains fix-bug post-investigation entry"
    return 0
  else
    echo "  FAIL F1: Context-Specific Routing table missing fix-bug post-investigation entry in $SHARED_EVALUATOR" >&2
    return 1
  fi
}

# ── Test case F: fix-bug routing table entry ──────────────────────────────────
echo "Test case F: fix-bug post-investigation entry in Context-Specific Routing table"
test_case_F_pass=true

if test_routing_table_contains_fix_bug; then
  : # pass message already printed
else
  test_case_F_pass=false
fi

if $test_case_F_pass; then
  echo "  → Test case F: PASS"
  (( PASS++ ))
else
  echo "  → Test case F: FAIL" >&2
  (( FAIL++ ))
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "PASS:    $PASS"
echo "FAIL:    $FAIL"
echo "PENDING: $PENDING"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAIL ($FAIL test case(s) failed)"
  exit 1
else
  echo "RESULT: PASS (all non-PENDING test cases passed; $PENDING pending)"
  exit 0
fi
