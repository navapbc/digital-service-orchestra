#!/usr/bin/env bash
# Structural boundary validation for the GHA scanner prompt and SKILL.md Step 0.
#
# Tests:
#   1. gha-scanner.md exists and has required structural sections
#   2. gha-scanner.md contains pre-flight probe logic (required section heading)
#   3. gha-scanner.md contains tag dedup check (gha:<workflow>) reference
#   4. gha-scanner.md contains compact summary schema (workflows_checked, tickets_created,
#      failures_already_tracked fields)
#   5. debug-everything SKILL.md contains Step 0 section referencing gha_workflows
#
# Per behavioral-testing-standard Rule 5: non-executable instruction files are tested only
# at the structural boundary (required section headings, mandatory fields, structural markers).
# Content assertions check section headings and schema field names, NOT implementation wording.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCANNER_MD="${REPO_ROOT}/plugins/dso/skills/debug-everything/prompts/gha-scanner.md"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/debug-everything/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
# fail() prints a machine-readable "FAIL: section_name" line required by parse_failing_tests_from_output
# followed by the human-readable message.
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: gha-scanner.md exists
# ---------------------------------------------------------------------------
echo "=== test_gha_scanner_file_exists ==="
SECTION="test_gha_scanner_file_exists"

if [ -s "$SCANNER_MD" ]; then
  pass "gha-scanner.md exists and is non-empty"
else
  fail "gha-scanner.md missing or empty at: $SCANNER_MD"
fi

# ---------------------------------------------------------------------------
# Test 2: Pre-flight probe section heading present
# ---------------------------------------------------------------------------
echo ""
echo "=== test_gha_scanner_preflight_probe ==="
SECTION="test_gha_scanner_preflight_probe"

if [ ! -f "$SCANNER_MD" ]; then
  fail "gha-scanner.md missing — cannot check pre-flight probe section"
else
  # The pre-flight probe must be documented in the file.
  # Check for 'GHA scan unavailable' signal (structural contract: error signal name)
  if grep -qiE "GHA scan unavailable" "$SCANNER_MD"; then
    pass "gha-scanner.md contains 'GHA scan unavailable' error signal (pre-flight probe contract)"
  else
    fail "gha-scanner.md missing 'GHA scan unavailable' error signal — pre-flight probe not documented"
  fi

  # Check for per_page or pre-flight keyword indicating probe mechanism
  if grep -qiE "per_page|pre.flight|probe" "$SCANNER_MD"; then
    pass "gha-scanner.md references pre-flight probe mechanism (per_page/pre-flight/probe)"
  else
    fail "gha-scanner.md missing pre-flight probe mechanism reference (per_page/pre-flight/probe)"
  fi
fi

# ---------------------------------------------------------------------------
# Test 3: Tag dedup check — gha:<workflow> pattern present
# ---------------------------------------------------------------------------
echo ""
echo "=== test_gha_scanner_tag_dedup ==="
SECTION="test_gha_scanner_tag_dedup"

if [ ! -f "$SCANNER_MD" ]; then
  fail "gha-scanner.md missing — cannot check tag dedup section"
else
  if grep -qE "gha:" "$SCANNER_MD"; then
    pass "gha-scanner.md contains 'gha:' tag prefix (dedup contract)"
  else
    fail "gha-scanner.md missing 'gha:' tag prefix — tag dedup logic not documented"
  fi
fi

# ---------------------------------------------------------------------------
# Test 4: Compact summary schema fields present
# ---------------------------------------------------------------------------
echo ""
echo "=== test_gha_scanner_compact_summary_schema ==="
SECTION="test_gha_scanner_compact_summary_schema"

if [ ! -f "$SCANNER_MD" ]; then
  fail "gha-scanner.md missing — cannot check compact summary schema"
else
  if grep -q "workflows_checked" "$SCANNER_MD"; then
    pass "gha-scanner.md contains 'workflows_checked' summary field"
  else
    fail "gha-scanner.md missing 'workflows_checked' summary field"
  fi

  if grep -q "tickets_created" "$SCANNER_MD"; then
    pass "gha-scanner.md contains 'tickets_created' summary field"
  else
    fail "gha-scanner.md missing 'tickets_created' summary field"
  fi

  if grep -q "failures_already_tracked" "$SCANNER_MD"; then
    pass "gha-scanner.md contains 'failures_already_tracked' summary field"
  else
    fail "gha-scanner.md missing 'failures_already_tracked' summary field"
  fi
fi

# ---------------------------------------------------------------------------
# Test 5: SKILL.md contains Step 0 section referencing gha_workflows
# ---------------------------------------------------------------------------
echo ""
echo "=== test_skill_md_step0_section ==="
SECTION="test_skill_md_step0_section"

if [ ! -f "$SKILL_MD" ]; then
  fail "SKILL.md missing at: $SKILL_MD"
else
  if grep -q "Step 0" "$SKILL_MD"; then
    pass "debug-everything SKILL.md contains 'Step 0' section"
  else
    fail "debug-everything SKILL.md missing 'Step 0' section"
  fi

  if grep -q "gha_workflows" "$SKILL_MD"; then
    pass "debug-everything SKILL.md references 'gha_workflows' config key"
  else
    fail "debug-everything SKILL.md missing 'gha_workflows' config key reference"
  fi

  if grep -q "gha:" "$SKILL_MD"; then
    pass "debug-everything SKILL.md references 'gha:' tag prefix (dedup)"
  else
    fail "debug-everything SKILL.md missing 'gha:' tag prefix reference"
  fi

  if grep -qiE "gha_scan_enabled|gha scan skipped" "$SKILL_MD"; then
    pass "debug-everything SKILL.md references gha_scan_enabled or skip log"
  else
    fail "debug-everything SKILL.md missing gha_scan_enabled/skip-log reference"
  fi
fi

# ---------------------------------------------------------------------------
# Test 5b: gha-scanner.md includes action_required in failure conclusions
# ---------------------------------------------------------------------------
echo ""
echo "=== test_gha_scanner_action_required_conclusion ==="
SECTION="test_gha_scanner_action_required_conclusion"

if [ ! -f "$SCANNER_MD" ]; then
  fail "gha-scanner.md missing — cannot check failure conclusions"
else
  if grep -q "action_required" "$SCANNER_MD"; then
    pass "gha-scanner.md includes 'action_required' in failure conclusions"
  else
    fail "gha-scanner.md missing 'action_required' failure conclusion (silently drops runs requiring environment approval)"
  fi
fi

# ---------------------------------------------------------------------------
# Test 5c: gha-scanner.md uses full .claude/scripts/dso path (not bare 'dso')
# ---------------------------------------------------------------------------
echo ""
echo "=== test_gha_scanner_dso_path ==="
SECTION="test_gha_scanner_dso_path"

if [ ! -f "$SCANNER_MD" ]; then
  fail "gha-scanner.md missing — cannot check dso path"
else
  if grep -q '\.claude/scripts/dso' "$SCANNER_MD"; then
    pass "gha-scanner.md uses '.claude/scripts/dso' path prefix"
  else
    fail "gha-scanner.md missing '.claude/scripts/dso' prefix — bare 'dso' is not on PATH in worktree sub-agents"
  fi
fi

# ---------------------------------------------------------------------------
# Test 6: dso-config.conf contains gha_scan_enabled and gha_workflows keys
# ---------------------------------------------------------------------------
echo ""
echo "=== test_config_keys_documented ==="
SECTION="test_config_keys_documented"

CONFIG_CONF="${REPO_ROOT}/.claude/dso-config.conf"
if [ ! -f "$CONFIG_CONF" ]; then
  fail "dso-config.conf missing at: $CONFIG_CONF"
else
  if grep -q "gha_scan_enabled" "$CONFIG_CONF"; then
    pass "dso-config.conf documents 'gha_scan_enabled' config key"
  else
    fail "dso-config.conf missing 'gha_scan_enabled' config key"
  fi

  if grep -q "gha_workflows" "$CONFIG_CONF"; then
    pass "dso-config.conf documents 'gha_workflows' config key"
  else
    fail "dso-config.conf missing 'gha_workflows' config key"
  fi
fi

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
