#!/usr/bin/env bash
# Structural tests for brainstorm SKILL.md Phase 1 Gate Step 1.5 (UI Intent Detection)
# and 3 new prompt files: ui-keyword-trigger.md, ui-detection-classifier.md, ux-probe-set.md.
# NOTE: These tests are intentionally RED — the SKILL.md sections and prompt files they check
# do not exist yet. They will turn GREEN when the implementation task adds the content.
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

# ============================================================
echo "=== test_ui_detection_step ==="
SECTION="test_ui_detection_step"

if grep -qiE 'Phase 1 Gate Step 1\.5|Step 1\.5.*UI|UI.*[Ii]ntent.*[Dd]etect' "$SKILL_MD"; then
  pass "SKILL.md contains Phase 1 Gate Step 1.5 UI intent detection step"
else
  fail "SKILL.md missing Phase 1 Gate Step 1.5 UI intent detection step"
fi

# ============================================================
echo ""
echo "=== test_ux_probe_fired_flag ==="
SECTION="test_ux_probe_fired_flag"

if grep -qiE 'ux[_-]probe[_-]fired|ux-probe-fired' "$SKILL_MD"; then
  pass "SKILL.md references ux_probe_fired sentinel flag"
else
  fail "SKILL.md missing ux_probe_fired sentinel flag reference"
fi

# ============================================================
echo ""
echo "=== test_ux_probe_no_double_fire ==="
SECTION="test_ux_probe_no_double_fire"

if grep -qiE 'sentinel.*exist|flag.*exist|already.*fired|re.invocation.*guard|skip.*if.*flag|probe.*fired.*skip' "$SKILL_MD"; then
  pass "SKILL.md has re-invocation guard to prevent double-fire"
else
  fail "SKILL.md missing re-invocation guard to prevent double-fire"
fi

# ============================================================
echo ""
echo "=== test_ui_classifier_stub ==="
SECTION="test_ui_classifier_stub"

UI_KEYWORD_FILE="${REPO_ROOT}/plugins/dso/skills/brainstorm/prompts/ui-keyword-trigger.md"
if grep -q 'BRAINSTORM_UI_CLASSIFIER_STUB' "$SKILL_MD" 2>/dev/null || grep -q 'BRAINSTORM_UI_CLASSIFIER_STUB' "$UI_KEYWORD_FILE" 2>/dev/null; then
  pass "BRAINSTORM_UI_CLASSIFIER_STUB env var is documented"
else
  fail "BRAINSTORM_UI_CLASSIFIER_STUB env var missing from SKILL.md and prompt files"
fi

# ============================================================
echo ""
echo "=== test_prompt_files_exist ==="
SECTION="test_prompt_files_exist"

PROMPTS_DIR="${REPO_ROOT}/plugins/dso/skills/brainstorm/prompts"
for f in ui-keyword-trigger.md ui-detection-classifier.md ux-probe-set.md; do
  if test -f "${PROMPTS_DIR}/${f}"; then
    pass "Prompt file exists: $f"
  else
    fail "Prompt file missing: $f"
  fi
done

# ============================================================
echo ""
echo "=== test_probe_set_structure ==="
SECTION="test_probe_set_structure"

PROBE_SET="${REPO_ROOT}/plugins/dso/skills/brainstorm/prompts/ux-probe-set.md"
if grep -q '"id"\|^- id:\|id:' "$PROBE_SET" 2>/dev/null && grep -q '"dimension"\|dimension:' "$PROBE_SET" 2>/dev/null; then
  pass "ux-probe-set.md has structured probe format (id + dimension fields)"
else
  fail "ux-probe-set.md missing structured probe format (id and dimension fields)"
fi

# ============================================================
echo ""
echo "=== test_ui_keywords_default ==="
SECTION="test_ui_keywords_default"

KEYWORD_FILE="${REPO_ROOT}/plugins/dso/skills/brainstorm/prompts/ui-keyword-trigger.md"
if grep -qi 'form\|button\|dashboard\|modal' "$KEYWORD_FILE" 2>/dev/null; then
  pass "ui-keyword-trigger.md contains default surface-lexicon keywords"
else
  fail "ui-keyword-trigger.md missing default surface-lexicon keywords"
fi

# ============================================================
echo ""
echo "=== test_ui_keywords_override_replace ==="
SECTION="test_ui_keywords_override_replace"

KEYWORD_FILE="${REPO_ROOT}/plugins/dso/skills/brainstorm/prompts/ui-keyword-trigger.md"
if grep -qi 'replace\|replaces' "$KEYWORD_FILE" 2>/dev/null && grep -qi 'ui_keywords' "$KEYWORD_FILE" 2>/dev/null; then
  pass "ui-keyword-trigger.md documents replace (not merge) semantics for brainstorm.ui_keywords"
else
  fail "ui-keyword-trigger.md missing replace semantics for brainstorm.ui_keywords"
fi

# ============================================================
echo ""
echo "=== test_ui_classifier_failure_fallthrough ==="
SECTION="test_ui_classifier_failure_fallthrough"

if grep -qiE 'degradation|degrad.*notice|fallthrough|fall.through|fall.*through|classifier.*fail.*non.ui|non.ui.*fail' "$SKILL_MD"; then
  pass "SKILL.md documents classifier failure fallthrough to non-UI with degradation notice"
else
  fail "SKILL.md missing classifier failure fallthrough/degradation notice documentation"
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
