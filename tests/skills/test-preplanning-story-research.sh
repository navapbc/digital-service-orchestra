#!/usr/bin/env bash
# Structural validation for preplanning story-level research phase in SKILL.md.
# Tests: phase heading, trigger conditions, WebSearch/WebFetch references,
#        Research Notes structure, and graceful degradation language.
# All assertions are section-scoped to Phase G to avoid false positives
# from Phase 2.25 (Integration Research), which also references WebSearch/WebFetch.
# This IS the RED test — all assertions fail until Phase G is added to SKILL.md.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
# fail() prints a machine-readable "FAIL: section_name" line (required by
# parse_failing_tests_from_output in red-zone.sh, pattern '^FAIL: [a-zA-Z_][a-zA-Z0-9_-]*')
# followed by the human-readable message.
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract the Phase G section: from the Phase G heading to the next ## Phase heading.
# Returns empty string if the heading is not present.
extract_phase_g_section() {
  python3 - "$SKILL_MD" <<'PYEOF'
import sys, re

text = open(sys.argv[1]).read()
# Find Phase G heading — matches "## Phase G" or "### Phase G" with any suffix
start = re.search(r'^#{1,3} Phase G\b', text, re.MULTILINE)
if not start:
    sys.exit(0)
# Find the next "## Phase" heading after the start
rest = text[start.start():]
end_match = re.search(r'\n## Phase ', rest[1:])
if end_match:
    section = rest[:end_match.start() + 1]
else:
    section = rest
print(section)
PYEOF
}

PHASE_G_SECTION="$(extract_phase_g_section)"

echo "=== test_phase_heading ==="
SECTION="test_phase_heading"
if grep -qE "^#{1,3} Phase G" <<< "$PHASE_G_SECTION"; then
  pass "SKILL.md contains a Phase G heading for story-level research"
else
  fail "SKILL.md missing Phase G heading — expected '## Phase G' or '### Phase G'"
fi

echo ""
echo "=== test_trigger_conditions ==="
SECTION="test_trigger_conditions"
# Check for named trigger conditions relevant to story-level research:
# undocumented API, assumed data formats, low agent confidence
TRIGGER_COUNT=0
for trigger in \
  "undocumented API|undocumented.*api|api.*undocumented" \
  "assumed data format|assumed.*format|data format.*assum|unknown.*format|format.*unknown" \
  "low.*confidence|agent confidence|uncertain|unclear.*behavior|behavior.*unclear"; do
  if grep -qiE "$trigger" <<< "$PHASE_G_SECTION"; then
    TRIGGER_COUNT=$((TRIGGER_COUNT + 1))
  fi
done

if [ "$TRIGGER_COUNT" -ge 2 ]; then
  pass "Phase G section documents trigger conditions (found $TRIGGER_COUNT of 3)"
else
  fail "Phase G section needs at least 2 named trigger conditions (found $TRIGGER_COUNT) — expected: undocumented API, assumed data formats, low agent confidence"
fi

echo ""
echo "=== test_websearch_reference ==="
SECTION="test_websearch_reference"
# This assertion is section-scoped to Phase G to avoid matching Phase 2.25
if grep -qE "WebSearch|WebFetch" <<< "$PHASE_G_SECTION"; then
  pass "Phase G section references WebSearch or WebFetch"
else
  fail "Phase G section missing WebSearch or WebFetch reference (section-scoped check)"
fi

echo ""
echo "=== test_research_notes_structure ==="
SECTION="test_research_notes_structure"
# Check for at least 2 of 4 field names for Research Notes structure:
# trigger condition name, query summary, source URLs, key insight
FIELD_COUNT=0
for field_pattern in \
  "trigger.*condition|condition.*name|trigger name" \
  "query summary|search query|query used" \
  "source URL|source url|URLs?\b|link.*found" \
  "key insight|insight\b|finding\b|takeaway"; do
  if grep -qiE "$field_pattern" <<< "$PHASE_G_SECTION"; then
    FIELD_COUNT=$((FIELD_COUNT + 1))
  fi
done

if [ "$FIELD_COUNT" -ge 2 ]; then
  pass "Phase G section references Research Notes with at least 2 of 4 field names (found $FIELD_COUNT)"
else
  fail "Phase G section needs Research Notes with at least 2 of 4 field names: trigger condition name, query summary, source URLs, key insight (found $FIELD_COUNT)"
fi

echo ""
echo "=== test_graceful_degradation ==="
SECTION="test_graceful_degradation"
if grep -qiE "fail|unavailable|not available|graceful|degraded?|skip.*search|if.*fails?\b|when.*fails?\b|cannot.*search|search.*unavailable" <<< "$PHASE_G_SECTION"; then
  pass "Phase G section includes graceful degradation language"
else
  fail "Phase G section missing graceful degradation language for when WebSearch/WebFetch is unavailable or fails"
fi

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
