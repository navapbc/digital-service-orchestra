#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PASS=0
FAIL=0

# --- Test 1: CLAUDE.md scope-drift-reviewer agent routing entry ---
test_claude_md_scope_drift_reviewer_entry() {
  local desc="test_claude_md_scope_drift_reviewer_entry"
  if grep -q '`dso:scope-drift-reviewer`.*sonnet' "$REPO_ROOT/CLAUDE.md"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected dso:scope-drift-reviewer row with model sonnet in CLAUDE.md agent routing table"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 2: CLAUDE.md intent-search INTENT_CONFLICT ---
test_claude_md_intent_search_updated() {
  local desc="test_claude_md_intent_search_updated"
  if grep -q 'dso:intent-search' "$REPO_ROOT/CLAUDE.md" && grep 'dso:intent-search' "$REPO_ROOT/CLAUDE.md" | grep -q 'INTENT_CONFLICT'; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected INTENT_CONFLICT near dso:intent-search row in CLAUDE.md"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 3: CONFIGURATION-REFERENCE.md scope_drift.enabled ---
test_config_ref_scope_drift_enabled() {
  local desc="test_config_ref_scope_drift_enabled"
  if grep -q 'scope_drift\.enabled' "$REPO_ROOT/plugins/dso/docs/CONFIGURATION-REFERENCE.md"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected scope_drift.enabled in CONFIGURATION-REFERENCE.md"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 4: domain-logic.md scope drift gate ---
test_domain_logic_scope_drift_gate() {
  local desc="test_domain_logic_scope_drift_gate"
  if grep -qE 'scope.drift|scope_drift' "$REPO_ROOT/docs/reference/domain-logic.md"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected scope.drift or scope_drift in docs/reference/domain-logic.md"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 5: domain-logic.md INTENT_CONFLICT signal ---
test_domain_logic_intent_conflict_signal() {
  local desc="test_domain_logic_intent_conflict_signal"
  if grep -q 'INTENT_CONFLICT' "$REPO_ROOT/docs/reference/domain-logic.md"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected INTENT_CONFLICT in docs/reference/domain-logic.md"
    FAIL=$((FAIL + 1))
  fi
}

# --- Run all tests ---
test_claude_md_scope_drift_reviewer_entry
test_claude_md_intent_search_updated
test_config_ref_scope_drift_enabled
test_domain_logic_scope_drift_gate
test_domain_logic_intent_conflict_signal

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
