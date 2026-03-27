#!/usr/bin/env bash
# Structural validation for brainstorm web research phase in SKILL.md.
# Tests: phase heading, trigger conditions, agent-judgment guidance,
#        WebSearch/WebFetch references, Research Findings section structure,
#        and graceful degradation language.
# This IS the RED test — all assertions fail until the research phase is added.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract the research phase section: from the research phase heading line to the next
# ## or ### Step heading. Returns empty string if the heading is not present.
extract_research_section() {
  python3 - "$SKILL_MD" <<'PYEOF'
import sys, re

text = open(sys.argv[1]).read()
# Find start of research phase section
start = re.search(r'^(##+ .*[Ww]eb [Rr]esearch.*|##+ .*[Rr]esearch [Pp]hase.*)', text, re.MULTILINE)
if not start:
    sys.exit(0)
# Find the next ## or ### heading after the start
rest = text[start.start():]
end_match = re.search(r'\n(## |### Step)', rest[1:])
if end_match:
    section = rest[:end_match.start() + 1]
else:
    section = rest
print(section)
PYEOF
}

RESEARCH_SECTION="$(extract_research_section)"

echo "=== Research phase heading ==="
if echo "$RESEARCH_SECTION" | grep -qiE "web research"; then
  pass "SKILL.md contains a web research phase heading"
else
  fail "SKILL.md missing web research phase heading"
fi

echo ""
echo "=== Bright-line trigger conditions (at least 3 named conditions) ==="
# Count distinct named trigger conditions — lines/items that introduce a specific named condition.
TRIGGER_COUNT=0
for trigger in \
  "unfamiliar dependency|new dependency|new library|new package|unfamiliar.*library" \
  "external API|third-party API|external integration|external service" \
  "security|auth|authentication|credential" \
  "performance|scalability|throughput|latency" \
  "migration|upgrade|version|compatibility"; do
  if echo "$RESEARCH_SECTION" | grep -qiE "$trigger"; then
    TRIGGER_COUNT=$((TRIGGER_COUNT + 1))
  fi
done

if [ "$TRIGGER_COUNT" -ge 3 ]; then
  pass "Research phase section contains at least 3 named bright-line trigger conditions ($TRIGGER_COUNT found)"
else
  fail "Research phase section needs at least 3 named bright-line trigger conditions (found $TRIGGER_COUNT)"
fi

echo ""
echo "=== One-sentence examples for trigger conditions ==="
# Each trigger condition should have an illustrative example sentence
if echo "$RESEARCH_SECTION" | grep -qiE "example|e\.g\.|for instance|such as"; then
  pass "Research phase section includes trigger condition examples"
else
  fail "Research phase section missing one-sentence examples for trigger conditions"
fi

echo ""
echo "=== Agent-judgment trigger guidance paragraph ==="
# There should be a paragraph describing when agent judgment applies (edge cases beyond bright-line triggers)
if echo "$RESEARCH_SECTION" | grep -qiE "judgment|agent.*judge|use.*judgment|exercise.*judgment|when.*unclear|when.*uncertain|when.*doubt"; then
  pass "Research phase section contains agent-judgment trigger guidance"
else
  fail "Research phase section missing agent-judgment trigger guidance paragraph"
fi

echo ""
echo "=== WebSearch and WebFetch references within research phase section ==="
if echo "$RESEARCH_SECTION" | grep -q "WebSearch"; then
  pass "Research phase section references WebSearch"
else
  fail "Research phase section missing WebSearch reference"
fi

if echo "$RESEARCH_SECTION" | grep -q "WebFetch"; then
  pass "Research phase section references WebFetch"
else
  fail "Research phase section missing WebFetch reference"
fi

echo ""
echo "=== Research Findings section structure ==="
if echo "$RESEARCH_SECTION" | grep -qiE "[Rr]esearch [Ff]indings|findings section"; then
  pass "Research phase section contains a Research Findings structure"
else
  fail "Research phase section missing Research Findings section structure"
fi

# Item-level format: trigger condition name
if echo "$RESEARCH_SECTION" | grep -qiE "trigger.*condition|condition.*name|trigger name"; then
  pass "Research Findings format includes trigger condition name"
else
  fail "Research Findings format missing trigger condition name field"
fi

# Item-level format: query summary
if echo "$RESEARCH_SECTION" | grep -qiE "query summary|search query|query used|what.*searched"; then
  pass "Research Findings format includes query summary"
else
  fail "Research Findings format missing query summary field"
fi

# Item-level format: source URLs
if echo "$RESEARCH_SECTION" | grep -qiE "source URL|source url|URLs?.*found|link.*found|references?.*URL"; then
  pass "Research Findings format includes source URLs"
else
  fail "Research Findings format missing source URLs field"
fi

# Item-level format: key insight
if echo "$RESEARCH_SECTION" | grep -qiE "key insight|insight|finding|takeaway|summary.*result"; then
  pass "Research Findings format includes key insight"
else
  fail "Research Findings format missing key insight field"
fi

echo ""
echo "=== Graceful degradation when WebSearch/WebFetch fails ==="
if echo "$RESEARCH_SECTION" | grep -qiE "fail|unavailable|not available|graceful|degraded?|skip.*search|if.*fails?\b|when.*fails?\b"; then
  pass "Research phase section describes graceful degradation on tool failure"
else
  fail "Research phase section missing graceful degradation guidance for WebSearch/WebFetch failures"
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
