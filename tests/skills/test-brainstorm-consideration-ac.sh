#!/usr/bin/env bash
# Structural boundary test for consideration AC injection in brainstorm SKILL.md.
# Tests: injected provenance category, AC construction from CONSIDERATION signals,
# deduplication by shared resource name, rendering rule at approval gate, placement
# under ## Cross-Epic Interactions section, and provenance summary formula.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

# skill-refactor: brainstorm phases extracted. Rebind SKILL_MD to the aggregated
# corpus so content moved to phases/*.md remains reachable by content-presence greps.
# Tests that assert SKILL.md-specific structure should use "$_origSKILL_MD" instead.
_origSKILL_MD="$SKILL_MD"
source "$(git rev-parse --show-toplevel)/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_MD=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT


PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: "injected" appears in the Provenance Tracking section as a 5th category
# ---------------------------------------------------------------------------
echo "=== test_injected_provenance_category ==="
SECTION="test_injected_provenance_category"

_provenance_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Find the Provenance Tracking section
match = re.search(r'(?m)(### Provenance Tracking.*?)(?=^###|^##\s|\Z)', content, re.DOTALL)
if match:
    print(match.group(1))
EOF
) || true

if [ -z "$_provenance_section" ]; then
  fail "SKILL.md missing Provenance Tracking section"
else
  pass "SKILL.md has Provenance Tracking section"
fi

if echo "$_provenance_section" | grep -q 'injected'; then
  pass "Provenance Tracking section contains 'injected' as a provenance category"
else
  fail "Provenance Tracking section missing 'injected' as a 5th provenance category"
fi

# Verify it is listed alongside the other 4 categories (explicit, confirmed-via-gap-question, inferred, researched)
for cat in "explicit" "confirmed-via-gap-question" "inferred" "researched"; do
  if echo "$_provenance_section" | grep -q "$cat"; then
    pass "Provenance Tracking section contains category: $cat"
  else
    fail "Provenance Tracking section missing category: $cat"
  fi
done

# ---------------------------------------------------------------------------
# Test 2: AC construction instruction with all 3 required fields
# ---------------------------------------------------------------------------
echo ""
echo "=== test_consideration_ac_construction ==="
SECTION="test_consideration_ac_construction"

_full_content=$(cat "$SKILL_MD")

# Must contain instruction for constructing ACs from CONSIDERATION signals
if echo "$_full_content" | grep -qi 'consideration'; then
  pass "SKILL.md contains instruction referencing CONSIDERATION signals"
else
  fail "SKILL.md missing instruction for handling CONSIDERATION-severity signals"
fi

# Field (a): shared resource name
if echo "$_full_content" | grep -qi 'shared.resource'; then
  pass "SKILL.md contains 'shared resource' field in AC construction instruction"
else
  fail "SKILL.md missing 'shared resource name' field in AC construction instruction"
fi

# Field (b): overlapping epic ID + title
if echo "$_full_content" | grep -qi 'overlapping.epic'; then
  pass "SKILL.md contains 'overlapping epic' field in AC construction instruction"
else
  fail "SKILL.md missing 'overlapping epic ID + title' field in AC construction instruction"
fi

# Field (c): falsifiable integration constraint
if echo "$_full_content" | grep -qi 'integration.constraint\|falsifiable'; then
  pass "SKILL.md contains 'integration constraint' / 'falsifiable' field in AC construction instruction"
else
  fail "SKILL.md missing 'falsifiable integration constraint' field in AC construction instruction"
fi

# ---------------------------------------------------------------------------
# Test 3: Deduplication instruction by shared resource name
# ---------------------------------------------------------------------------
echo ""
echo "=== test_consideration_ac_deduplication ==="
SECTION="test_consideration_ac_deduplication"

if echo "$_full_content" | grep -qi 'deduplicat'; then
  pass "SKILL.md contains deduplication instruction for CONSIDERATION signals"
else
  fail "SKILL.md missing deduplication instruction (by shared resource name)"
fi

# The deduplication must be by shared resource name / shared_resource
if echo "$_full_content" | grep -qi 'shared.resource'; then
  pass "Deduplication instruction references shared resource name as deduplication key"
else
  fail "Deduplication instruction does not reference shared resource name as key"
fi

# ---------------------------------------------------------------------------
# Test 4: "injected" rendering rule at approval gate (bold, same as inferred/researched)
# ---------------------------------------------------------------------------
echo ""
echo "=== test_injected_rendering_rule ==="
SECTION="test_injected_rendering_rule"

_approval_gate_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Find the approval gate section. Matches the SKILL.md pointer heading
# (### Step 4: Approval Gate) or the phase file's top-level heading
# (# Phase 2 Step 4 — Approval Gate).
patterns = [
    r'(?m)(# Phase 2 Step 4.*?[Aa]pproval [Gg]ate.*?)(?=^# [A-Z]|\Z)',
    r'(?m)(### Step 4: Approval Gate.*?)(?=^###\s|\Z)',
]
for pat in patterns:
    m = re.search(pat, content, re.DOTALL)
    if m:
        print(m.group(1))
        sys.exit(0)
EOF
) || true

if [ -z "$_approval_gate_section" ]; then
  fail "SKILL.md missing Step 4 Approval Gate section"
else
  pass "SKILL.md has Step 4 Approval Gate section"
fi

# "injected" must appear in the approval gate rendering section
if echo "$_approval_gate_section" | grep -q 'injected'; then
  pass "Approval gate section contains 'injected' rendering rule"
else
  fail "Approval gate section missing 'injected' rendering rule"
fi

# The injected rule should specify bold rendering (same as inferred/researched)
if echo "$_approval_gate_section" | grep -i 'injected' | grep -qi 'bold'; then
  pass "Approval gate 'injected' rule specifies bold rendering"
else
  fail "Approval gate 'injected' rule missing bold rendering specification"
fi

# ---------------------------------------------------------------------------
# Test 5: "## Cross-Epic Interactions" section reference
# ---------------------------------------------------------------------------
echo ""
echo "=== test_cross_epic_interactions_section ==="
SECTION="test_cross_epic_interactions_section"

if echo "$_full_content" | grep -q '## Cross-Epic Interactions'; then
  pass "SKILL.md references '## Cross-Epic Interactions' section for injected AC placement"
else
  fail "SKILL.md missing reference to '## Cross-Epic Interactions' section"
fi

# ---------------------------------------------------------------------------
# Test 6: Provenance summary formula mentions "injected" count
# ---------------------------------------------------------------------------
echo ""
echo "=== test_provenance_summary_injected_count ==="
SECTION="test_provenance_summary_injected_count"

# The summary formula line must include injected count (e.g., "J injected from cross-epic scan")
if echo "$_full_content" | grep -qi 'injected.*cross.epic\|cross.epic.*injected'; then
  pass "Provenance summary formula mentions 'injected' count from cross-epic scan"
else
  fail "Provenance summary formula missing 'injected' count (e.g., 'J injected from cross-epic scan')"
fi

# The summary formula must appear near the approval gate
if echo "$_approval_gate_section" | grep -qi 'injected'; then
  pass "Approval gate section contains injected count in summary formula"
else
  fail "Approval gate section missing injected count in provenance summary formula"
fi

# ---------------------------------------------------------------------------
# Final results
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
