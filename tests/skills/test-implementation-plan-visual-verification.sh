#!/usr/bin/env bash
# tests/skills/test-implementation-plan-visual-verification.sh
# Structural boundary test: implementation-plan SKILL.md Step 3 must contain
# a Visual Verification subsection that defines the requires_visual_verification
# metadata contract for UI-touching tasks.
#
# Story 2d82-f15f / ticket c621-a025: enriched task descriptions must declare
# whether visual verification (e.g., Playwright) is required for the task.
# Downstream agents (sprint, fix-bug) key on the requires_visual_verification
# metadata token, the listed UI file patterns, and the playwright tool
# identifier. These are observable contract surfaces consumed by automation,
# not prose — they are the structural boundary the SKILL.md must publish.
#
# Per behavioral-testing-standard.md Rule 5 — instruction-file tests assert on
# structural boundary tokens (section heading + machine-consumable contract
# identifiers), not on body-text wording.
#
# Expected RED state: the SKILL.md does NOT yet contain the Visual Verification
# subsection; all four tests below should FAIL until the SKILL.md is updated.
#
# Usage:
#   bash tests/skills/test-implementation-plan-visual-verification.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-visual-verification.sh ==="
echo ""

# Extract Step 3 region (from "## Step 3" up to the next "## Step" heading).
_extract_step3() {
  awk '
    /^## Step 3/ { in_step=1; print; next }
    in_step && /^## Step / && !/^## Step 3/ { exit }
    in_step { print }
  ' "$SKILL_FILE"
}

# Extract the visual verification subsection (### heading containing "visual"
# case-insensitive, up to the next ### heading) from within Step 3.
_extract_visual_subsection() {
  _extract_step3 | awk '
    BEGIN { IGNORECASE=1 }
    /^### .*visual/ { in_sub=1; print; next }
    in_sub && /^### / { exit }
    in_sub { print }
  '
}

# ===========================================================================
# test_visual_verification_detection_heading_present
#
# Structural boundary: a subsection heading containing "Visual Verification"
# or "visual_verification" must exist within Step 3. The heading is the
# anchor downstream agents and human readers use to locate the contract.
# ===========================================================================
test_visual_verification_detection_heading_present() {
  local _step3
  _step3=$(_extract_step3)

  local _found=0
  if echo "$_step3" | grep -qiE '^### .*(visual verification|visual_verification)'; then
    _found=1
  fi

  assert_eq \
    "test_visual_verification_detection_heading_present: Step 3 must contain a '### Visual Verification' (or visual_verification) subsection heading" \
    "1" "$_found"
}

# ===========================================================================
# test_visual_verification_metadata_field_mentioned
#
# Structural boundary: the metadata field name `requires_visual_verification`
# is the contract token downstream consumers (sprint, fix-bug) key on. Its
# literal token must appear in Step 3.
# ===========================================================================
test_visual_verification_metadata_field_mentioned() {
  local _step3
  _step3=$(_extract_step3)

  local _found=0
  if echo "$_step3" | grep -q 'requires_visual_verification'; then
    _found=1
  fi

  assert_eq \
    "test_visual_verification_metadata_field_mentioned: Step 3 must reference the requires_visual_verification metadata token" \
    "1" "$_found"
}

# ===========================================================================
# test_visual_verification_ui_file_patterns_listed
#
# Structural boundary: the visual verification subsection must enumerate at
# least 2 UI file patterns from the canonical set so agents can deterministically
# decide when to set requires_visual_verification: true. These extensions are
# pattern tokens consumed by classification logic, not prose.
# ===========================================================================
test_visual_verification_ui_file_patterns_listed() {
  local _subsection
  _subsection=$(_extract_visual_subsection)

  # The patterns must be listed inside the visual-verification subsection
  # (the structural contract surface). If the subsection heading is absent,
  # the contract is missing — record 0 patterns rather than searching the
  # broader Step 3 region (which would mask the contract gap).
  local _count=0
  for _pat in '\.css' '\.js\b' '\.ts\b' '\.tsx' '\.html' '\.jinja2' 'component'; do
    if echo "$_subsection" | grep -qiE "$_pat"; then
      _count=$((_count + 1))
    fi
  done

  local _ok=0
  [[ "$_count" -ge 2 ]] && _ok=1

  assert_eq \
    "test_visual_verification_ui_file_patterns_listed: visual verification section must list >= 2 UI file patterns (got $_count)" \
    "1" "$_ok"
}

# ===========================================================================
# test_visual_verification_playwright_ac_mentioned
#
# Structural boundary: `playwright` is the named verification tool referenced
# by the broader plugin (see playwright-debug skill, dso:playwright-debug).
# The visual verification contract must name it as the verification tool so
# downstream agents wire to the correct runner.
# ===========================================================================
test_visual_verification_playwright_ac_mentioned() {
  local _subsection
  _subsection=$(_extract_visual_subsection)

  if [[ -z "$_subsection" ]]; then
    _subsection=$(_extract_step3)
  fi

  local _found=0
  if echo "$_subsection" | grep -qi 'playwright'; then
    _found=1
  fi

  assert_eq \
    "test_visual_verification_playwright_ac_mentioned: visual verification section must name playwright as the verification tool" \
    "1" "$_found"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_visual_verification_detection_heading_present
test_visual_verification_metadata_field_mentioned
test_visual_verification_ui_file_patterns_listed
test_visual_verification_playwright_ac_mentioned

print_summary
