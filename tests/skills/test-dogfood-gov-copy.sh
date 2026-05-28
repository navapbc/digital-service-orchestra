#!/usr/bin/env bash
# test-dogfood-gov-copy.sh — Test suite for the dogfood harness acceptance bar.
#
# Tests:
#   1. Harness exits 0 with baseline + improved fixtures (acceptance bar passes)
#   2. Harness exits 1 when fk_grade bar cannot be met (improved worse than baseline)
#   3. Harness exits 1 when banned_words bar not met (improved still has banned words)
#   4. Harness exits 1 when active_voice bar not met (no improvement in voice)
#   5. Harness exits 2 on missing baseline artifact
#   6. Harness exits 2 on missing improved artifact

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
_PLUGIN_ROOT="$_REPO_ROOT/plugins/dso"

HARNESS="${_PLUGIN_ROOT}/scripts/dogfood-gov-copy.sh"
BASELINE="${_REPO_ROOT}/tests/fixtures/dogfood/bad-copy-baseline.yaml"
IMPROVED="${_REPO_ROOT}/tests/fixtures/dogfood/good-copy-improved.yaml"

PASS=0
FAIL=0

_pass() {
  echo "PASS: $1"
  PASS=$(( PASS + 1 ))
}

_fail() {
  echo "FAIL: $1"
  FAIL=$(( FAIL + 1 ))
}

# Create a temp directory for synthetic fixtures
TMPDIR_HARNESS="$(mktemp -d "${TMPDIR:-/tmp}/dogfood-test.XXXXXX")"
trap 'rm -rf "$TMPDIR_HARNESS"' EXIT

# ---------------------------------------------------------------------------
# Test 1: baseline + improved → harness exits 0
# ---------------------------------------------------------------------------
if bash "$HARNESS" --baseline "$BASELINE" --improved "$IMPROVED" > /dev/null 2>&1; then
  _pass "T1: harness exits 0 with standard fixtures (acceptance bar met)"
else
  _fail "T1: harness exited non-zero with standard fixtures — acceptance bar should pass"
fi

# ---------------------------------------------------------------------------
# Test 2: fk_grade bar miss → harness exits 1
# ---------------------------------------------------------------------------
# Improved copy has the SAME high fk_grades as the baseline — no decrease
IMPROVED_SAME_FK="$TMPDIR_HARNESS/improved-same-fk.yaml"
cat > "$IMPROVED_SAME_FK" <<'YAML'
schema_version: 1
items:
  - id: "item-1"
    values:
      label: "Placeholder"
      hint: "Placeholder hint."
      errors: {}
    rationale:
      rule_ids: []
      conflicts: []
      deviations: []
    checks:
      fk_grade: 17
      banned_words_found: []
      active_voice: true
      source: "deterministic-post-processor"
  - id: "item-2"
    values:
      label: "Placeholder"
      hint: "Placeholder hint."
      errors: {}
    rationale:
      rule_ids: []
      conflicts: []
      deviations: []
    checks:
      fk_grade: 17
      banned_words_found: []
      active_voice: true
      source: "deterministic-post-processor"
YAML

# Baseline with avg 16, improved same-fk has avg 17 → fk_grade bar fails
if bash "$HARNESS" --baseline "$BASELINE" --improved "$IMPROVED_SAME_FK" > /dev/null 2>&1; then
  _fail "T2: harness should exit 1 when fk_grade does not decrease"
else
  exit_code=$?
  if [[ $exit_code -eq 1 ]]; then
    _pass "T2: harness exits 1 when fk_grade bar not met"
  else
    _fail "T2: expected exit 1 when fk_grade bar not met (acceptance-bar failure), got $exit_code (likely a different error class — see harness exit-code taxonomy)"
  fi
fi

# ---------------------------------------------------------------------------
# Test 3: banned_words bar miss → harness exits 1
# ---------------------------------------------------------------------------
IMPROVED_BANNED="$TMPDIR_HARNESS/improved-still-banned.yaml"
cat > "$IMPROVED_BANNED" <<'YAML'
schema_version: 1
items:
  - id: "item-1"
    values:
      label: "Placeholder"
      hint: "Placeholder hint."
      errors: {}
    rationale:
      rule_ids: []
      conflicts: []
      deviations: []
    checks:
      fk_grade: 4
      banned_words_found:
        - "utilize"
      active_voice: true
      source: "deterministic-post-processor"
YAML

if bash "$HARNESS" --baseline "$BASELINE" --improved "$IMPROVED_BANNED" > /dev/null 2>&1; then
  _fail "T3: harness should exit 1 when banned_words not cleared"
else
  exit_code=$?
  if [[ $exit_code -eq 1 ]]; then
    _pass "T3: harness exits 1 when banned_words bar not met"
  else
    _fail "T3: expected exit 1 when banned_words bar not met (acceptance-bar failure), got $exit_code"
  fi
fi

# ---------------------------------------------------------------------------
# Test 4: active_voice bar miss → harness exits 1
# ---------------------------------------------------------------------------
IMPROVED_PASSIVE="$TMPDIR_HARNESS/improved-passive.yaml"
cat > "$IMPROVED_PASSIVE" <<'YAML'
schema_version: 1
items:
  - id: "item-1"
    values:
      label: "Placeholder"
      hint: "Placeholder hint."
      errors: {}
    rationale:
      rule_ids: []
      conflicts: []
      deviations: []
    checks:
      fk_grade: 4
      banned_words_found: []
      active_voice: false
      source: "deterministic-post-processor"
YAML

if bash "$HARNESS" --baseline "$BASELINE" --improved "$IMPROVED_PASSIVE" > /dev/null 2>&1; then
  _fail "T4: harness should exit 1 when active_voice rate does not improve by >= 20pp"
else
  exit_code=$?
  if [[ $exit_code -eq 1 ]]; then
    _pass "T4: harness exits 1 when active_voice bar not met"
  else
    _fail "T4: expected exit 1 when active_voice bar not met (acceptance-bar failure), got $exit_code"
  fi
fi

# ---------------------------------------------------------------------------
# Test 5: missing baseline → harness exits 2
# ---------------------------------------------------------------------------
exit_code=0
bash "$HARNESS" --baseline "/nonexistent/baseline.yaml" --improved "$IMPROVED" > /dev/null 2>&1 || exit_code=$?
if [[ $exit_code -eq 2 ]]; then
  _pass "T5: harness exits 2 on missing baseline"
else
  _fail "T5: expected exit 2 on missing baseline, got $exit_code"
fi

# ---------------------------------------------------------------------------
# Test 6: missing improved → harness exits 2
# ---------------------------------------------------------------------------
exit_code=0
bash "$HARNESS" --baseline "$BASELINE" --improved "/nonexistent/improved.yaml" > /dev/null 2>&1 || exit_code=$?
if [[ $exit_code -eq 2 ]]; then
  _pass "T6: harness exits 2 on missing improved artifact"
else
  _fail "T6: expected exit 2 on missing improved artifact, got $exit_code"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
