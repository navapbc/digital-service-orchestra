#!/usr/bin/env bash
# Structural + content tests for progressive validation sections in brainstorm SKILL.md.
# Tests: understanding summary, intent gap analysis, provenance categories, bold/normal mapping,
# annotation summary line, clean-text instruction, bounded gap loop, negative tests.
# NOTE: These tests are intentionally RED — the SKILL.md sections they check do not exist yet.
# They will turn GREEN when the implementation task adds progressive validation to SKILL.md.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
# fail() prints a machine-readable "FAIL: section_name" line (required by parse_failing_tests_from_output
# in red-zone.sh, which uses pattern '^FAIL: [a-zA-Z_][a-zA-Z0-9_-]*') followed by the human-readable
# message. The section name is set by each "=== section_name ===" block below.
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract a section from SKILL.md bounded by a heading and the next same-or-higher-level heading.
# Uses python3 for BSD sed compatibility (macOS sed lacks -z / multiline).
# Usage: extract_section "## Heading Text"
# Returns: the content between that heading and the next heading at the same level.
extract_section() {
  local heading="$1"
  python3 - "$SKILL_MD" "$heading" <<'EOF'
import sys, re

filepath = sys.argv[1]
heading = sys.argv[2]

with open(filepath, 'r') as f:
    content = f.read()

# Determine heading level (number of leading #)
level = len(heading) - len(heading.lstrip('#'))
prefix = '#' * level

# Escape heading for regex
escaped = re.escape(heading.lstrip('# ').strip())

# Match from heading to next heading of same or higher level
pattern = rf'(?m)^{re.escape(prefix)}\s+{escaped}.*?(?=^#{"{1," + str(level) + "}"}[^#]|\Z)'
match = re.search(pattern, content, re.DOTALL)
if match:
    print(match.group(0))
EOF
}

# Extract Phase 1 Gate section (progressive validation gate / understanding summary gate)
_extract_phase1_gate() {
  python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Look for Phase 1 Gate or Understanding Summary Gate section
patterns = [
    r'(?m)(Phase 1[^#\n]*[Gg]ate.*?)(?=^##|\Z)',
    r'(?m)(### .*[Uu]nderstanding [Ss]ummary.*?)(?=^###|\Z)',
    r'(?m)(## Phase 1[^#\n]*?)(?=^##|\Z)',
    r'(?m)(###.*[Pp]rogressive [Vv]alidation.*?)(?=^###|\Z)',
    r'(?m)(###.*[Vv]alidation [Gg]ate.*?)(?=^###|\Z)',
    r'(?m)(## Progressive Validation.*?)(?=^##|\Z)',
]
for pattern in patterns:
    match = re.search(pattern, content, re.DOTALL)
    if match:
        print(match.group(1))
        sys.exit(0)
sys.exit(1)
EOF
}

# Extract Phase 3 section
_extract_phase3_section() {
  python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Look for Phase 3 section
patterns = [
    r'(?m)(## Phase 3.*?)(?=^##|\Z)',
    r'(?m)(### Phase 3.*?)(?=^###|\Z)',
    r'(?m)(## .*[Ee]pic [Ss]pec.*?)(?=^##|\Z)',
]
for pattern in patterns:
    match = re.search(pattern, content, re.DOTALL)
    if match:
        print(match.group(1))
        sys.exit(0)
sys.exit(1)
EOF
}

# Extract gap analysis section
_extract_gap_analysis_section() {
  python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Look for gap analysis section
patterns = [
    r'(?m)(###.*[Gg]ap [Aa]nalysis.*?)(?=^###|\Z)',
    r'(?m)(###.*[Ii]ntent [Gg]ap.*?)(?=^###|\Z)',
    r'(?m)(## .*[Gg]ap.*?)(?=^##|\Z)',
]
for pattern in patterns:
    match = re.search(pattern, content, re.DOTALL)
    if match:
        print(match.group(1))
        sys.exit(0)
sys.exit(1)
EOF
}

# ============================================================
echo "=== test_understanding_summary ==="
SECTION="test_understanding_summary"

_phase1_gate=$(_extract_phase1_gate) || true

if [ -z "$_phase1_gate" ]; then
  fail "SKILL.md missing Phase 1 Gate / understanding summary section"
else
  pass "SKILL.md has a Phase 1 Gate or understanding summary section"
fi

# Understanding summary must contain key elements covering problem, users, scope, success, confirmation
for keyword in problem users scope success confirmation; do
  if echo "$_phase1_gate" | grep -qi "$keyword"; then
    pass "Phase 1 Gate section contains keyword: $keyword"
  else
    fail "Phase 1 Gate section missing keyword: $keyword"
  fi
done

# ============================================================
echo ""
echo "=== test_intent_gap_analysis ==="
SECTION="test_intent_gap_analysis"

_phase1_gate2=$(_extract_phase1_gate) || true

# Gap analysis must reference inferred or assumed content
if echo "$_phase1_gate2" | grep -qiE 'inferred|assumed'; then
  pass "Phase 1 Gate section references inferred/assumed content for gap analysis"
else
  fail "Phase 1 Gate section missing inferred/assumed language for intent gap analysis"
fi

# Gap analysis must mention targeted questions
if echo "$_phase1_gate2" | grep -qiE 'targeted questions|targeted question|gap question'; then
  pass "Phase 1 Gate section references targeted questions for gap analysis"
else
  fail "Phase 1 Gate section missing targeted questions reference"
fi

# ============================================================
echo ""
echo "=== test_provenance_categories ==="
SECTION="test_provenance_categories"

# All four provenance categories must appear in the SKILL.md
for category in explicit confirmed-via-gap-question inferred researched; do
  if grep -q "$category" "$SKILL_MD"; then
    pass "SKILL.md contains provenance category: $category"
  else
    fail "SKILL.md missing provenance category: $category"
  fi
done

# ============================================================
echo ""
echo "=== test_bold_normal_mapping_directionality ==="
SECTION="test_bold_normal_mapping_directionality"

# Inferred or researched items should be marked bold (uncertain/derived → visually prominent)
if grep -qiE 'inferred.*bold|researched.*bold|bold.*inferred|bold.*researched' "$SKILL_MD"; then
  pass "SKILL.md documents bold annotation for inferred or researched provenance"
else
  fail "SKILL.md missing bold annotation directive for inferred/researched provenance"
fi

# Explicit or confirmed items should be rendered normally (certain → no annotation needed)
if grep -qiE 'explicit.*normal|confirmed.*normal|normal.*explicit|normal.*confirmed' "$SKILL_MD"; then
  pass "SKILL.md documents normal (non-bold) rendering for explicit or confirmed provenance"
else
  fail "SKILL.md missing normal-text directive for explicit/confirmed provenance"
fi

# ============================================================
echo ""
echo "=== test_annotation_summary_line ==="
SECTION="test_annotation_summary_line"

# Annotation summary line phrase must appear in approval gate section
_gate_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

patterns = [
    r'(?m)(### Step 4:.*?[Aa]pproval.*?)(?=^###|\Z)',
    r'(?m)(## Approval Gate.*?)(?=^##|\Z)',
    r'(?m)(###.*[Aa]pproval [Gg]ate.*?)(?=^###|\Z)',
]
for pattern in patterns:
    match = re.search(pattern, content, re.DOTALL)
    if match:
        print(match.group(1))
        sys.exit(0)
sys.exit(1)
EOF
) || true

if echo "$_gate_section" | grep -qiE 'annotation summary|summary line|provenance summary'; then
  pass "Approval gate section contains annotation summary line reference"
else
  fail "Approval gate section missing annotation summary line reference"
fi

# Annotation summary line must appear BEFORE the option list
# We verify by checking the line number of the summary reference vs first option (a)
_summary_line=$(grep -n "annotation summary\|summary line\|provenance summary" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1) || true
_option_line=$(grep -n "(a)\|(b)\|(c)\|(d)\|option a\|option b" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1) || true

if [ -n "$_summary_line" ] && [ -n "$_option_line" ]; then
  if [ "$_summary_line" -lt "$_option_line" ]; then
    pass "Annotation summary line appears before the option list (line $_summary_line < $_option_line)"
  else
    fail "Annotation summary line must appear before option list (line $_summary_line >= $_option_line)"
  fi
else
  fail "Could not verify ordering: annotation summary line=$_summary_line, first option line=$_option_line"
fi

# ============================================================
echo ""
echo "=== test_clean_text_instruction ==="
SECTION="test_clean_text_instruction"

_phase3=$(_extract_phase3_section) || true

if [ -z "$_phase3" ]; then
  fail "SKILL.md missing Phase 3 section"
else
  pass "SKILL.md has a Phase 3 section"
fi

# Phase 3 must instruct to strip/clean bold annotations for the final epic spec
if echo "$_phase3" | grep -qiE 'strip|clean|no bold|remove bold|plain text|without.*bold'; then
  pass "Phase 3 section contains clean-text instruction (strip/clean/no bold)"
else
  fail "Phase 3 section missing clean-text instruction for final epic spec"
fi

# ============================================================
echo ""
echo "=== test_bounded_gap_loop ==="
SECTION="test_bounded_gap_loop"

# SKILL.md must specify a maximum of 3 questions in the gap loop
if grep -qiE 'at most 3|3 questions|maximum 3|max 3|up to 3' "$SKILL_MD"; then
  pass "SKILL.md specifies bounded gap loop (at most 3 / 3 questions)"
else
  fail "SKILL.md missing bounded gap loop specification (at most 3 or 3 questions)"
fi

# SKILL.md must reference opt-in mechanism for gap loop
if grep -qiE 'opt.in|opt in' "$SKILL_MD"; then
  pass "SKILL.md references opt-in mechanism for gap loop"
else
  fail "SKILL.md missing opt-in language for gap loop"
fi

# ============================================================
echo ""
echo "=== test_negative_no_bold_annotations_in_phase3 ==="
SECTION="test_negative_no_bold_annotations_in_phase3"

_phase3_neg=$(_extract_phase3_section) || true

# Phase 3 (final epic spec section) should NOT contain bold annotation rendering instructions —
# those belong in the Phase 1 Gate / progressive validation sections.
if echo "$_phase3_neg" | grep -qiE 'render.*bold|display.*bold|show.*bold|bold.*annotation.*render|annotation.*bold.*instruct'; then
  fail "Phase 3 section contains bold annotation rendering instructions (should be in Phase 1 Gate only)"
else
  pass "Phase 3 section does not contain bold annotation rendering instructions (correct)"
fi

# ============================================================
echo ""
echo "=== test_negative_gap_excludes_confirmed_content ==="
SECTION="test_negative_gap_excludes_confirmed_content"

_gap_section=$(_extract_gap_analysis_section) || true

if [ -z "$_gap_section" ]; then
  fail "SKILL.md missing gap analysis section"
else
  pass "SKILL.md has a gap analysis section"
fi

# Gap analysis section must indicate confirmed content is excluded/skipped from gaps
if echo "$_gap_section" | grep -qiE 'exclude|skip|not.*gap|confirmed.*not|already.*confirmed|no gap'; then
  pass "Gap analysis section excludes/skips confirmed content from gap questions"
else
  fail "Gap analysis section missing exclusion of confirmed content from gaps"
fi

# ============================================================
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
