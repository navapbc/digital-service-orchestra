#!/usr/bin/env bash
# tests/skills/test-implementation-plan-pattern-reference.sh
# Structural boundary test: implementation-plan SKILL.md Step 3 must contain
# a "### Pattern Reference" subsection that establishes:
#   - The subsection heading exists (structural boundary)
#   - It addresses low/medium familiarity tasks (familiarity rule)
#   - It mentions a 30-line cap on retrieved codebase examples (line-cap rule)
#
# Per behavioral-testing-standard.md Rule 5, instruction-file tests check the
# STRUCTURAL BOUNDARY (heading existence + structural keywords scoped to that
# subsection) — not body-text wording in arbitrary locations.
#
# Story: 90e1-a0e4 — Enriched task descriptions: Pattern Reference section
# Task: 91fa-a8f5
#
# Usage:
#   bash tests/skills/test-implementation-plan-pattern-reference.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-pattern-reference.sh ==="
echo ""

# Extract the "### Pattern Reference" subsection (from heading to next ### or ##).
_extract_pattern_reference_section() {
  awk '
    /^### Pattern Reference/ { found=1; print; next }
    found && /^### / { exit }
    found && /^## / { exit }
    found { print }
  ' "$SKILL_FILE"
}

# ===========================================================================
# test_pattern_reference_heading_present
#
# Structural boundary: the "### Pattern Reference" heading must exist in the
# SKILL.md file. This is the section-heading structural check allowed by
# behavioral-testing-standard.md Rule 5.
# ===========================================================================
test_pattern_reference_heading_present() {
  local _found=0
  grep -q '^### Pattern Reference' "$SKILL_FILE" && _found=1

  assert_eq \
    "test_pattern_reference_heading_present: '### Pattern Reference' heading exists in SKILL.md" \
    "1" "$_found"
}

# ===========================================================================
# test_pattern_reference_low_familiarity_rule
#
# Structural boundary: the Pattern Reference subsection must reference the
# familiarity gating rule. Accept either:
#   (a) BOTH "low" AND "medium" appear in the subsection, OR
#   (b) the keyword "familiarity" appears with at least one of low/medium.
# ===========================================================================
test_pattern_reference_low_familiarity_rule() {
  local _section
  _section=$(_extract_pattern_reference_section)

  local _has_low=0
  local _has_medium=0
  local _has_familiarity=0

  echo "$_section" | grep -qi 'low' && _has_low=1
  echo "$_section" | grep -qi 'medium' && _has_medium=1
  echo "$_section" | grep -qi 'familiarity' && _has_familiarity=1

  local _satisfied=0
  if [[ "$_has_low" == "1" && "$_has_medium" == "1" ]]; then
    _satisfied=1
  elif [[ "$_has_familiarity" == "1" && ( "$_has_low" == "1" || "$_has_medium" == "1" ) ]]; then
    _satisfied=1
  fi

  assert_eq \
    "test_pattern_reference_low_familiarity_rule: Pattern Reference subsection mentions low/medium familiarity gating" \
    "1" "$_satisfied"
}

# ===========================================================================
# test_pattern_reference_line_cap_rule
#
# Structural boundary: the Pattern Reference subsection must mention a 30-line
# cap on retrieved codebase examples. We check the literal "30" appears within
# the subsection bounds.
# ===========================================================================
test_pattern_reference_line_cap_rule() {
  local _section
  _section=$(_extract_pattern_reference_section)

  local _has_30=0
  echo "$_section" | grep -q '30' && _has_30=1

  assert_eq \
    "test_pattern_reference_line_cap_rule: Pattern Reference subsection mentions a 30-line cap" \
    "1" "$_has_30"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_pattern_reference_heading_present
test_pattern_reference_low_familiarity_rule
test_pattern_reference_line_cap_rule

print_summary
