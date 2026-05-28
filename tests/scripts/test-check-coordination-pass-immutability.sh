#!/usr/bin/env bash
# tests/scripts/test-check-coordination-pass-immutability.sh
# Unit tests for check-coordination-pass-immutability.sh
#
# Covers story c5ef-a8ba-e889-4c88, task 4a87-6476-3235-4c70.
# DDs tested:
#   dd-4 (c5ef): items whose rationale.rule_ids cite a canon rule with
#                hard_constraint=true have identical values pre- and post-
#                coordination-pass; a diff check confirms zero mutations on
#                those items.
#   dd-6 (c5ef): unit tests written and passing for all new or modified logic.
#
# Test plan:
#   1. PASS: hard-constraint items identical across first/second pass → exit 0
#   2. FAIL: hard-constraint item values.label changed → exit 1 with diagnostic
#   3. PASS: non-hard-constraint item changed → exit 0 (soft mutation accepted)

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../../plugins/dso" && pwd)"

DIFF_CHECK="$_PLUGIN_ROOT/scripts/check-coordination-pass-immutability.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== check-coordination-pass-immutability.sh unit tests ==="

# ---------------------------------------------------------------------------
# Prerequisite: script exists and is executable
# ---------------------------------------------------------------------------
echo ""
echo "--- prerequisite: diff-check script exists and is executable ---"
if [[ -x "$DIFF_CHECK" ]]; then
  pass "diff-check script exists and is executable"
else
  fail "diff-check script not found or not executable at: $DIFF_CHECK"
  echo "TOTAL: $PASS passed, $FAIL failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# Helper: write a synthetic first-pass artifact
# ---------------------------------------------------------------------------
# The hard-constraint item cites uswds-forms.label-sentence-case (hard_constraint=true).
# The soft item cites eighteen-f.voice-you-we (hard_constraint=false on eighteen-f file).

write_first_pass() {
  local path="$1"
  cat > "$path" <<'YAML'
schema_version: 1
items:
  - id: "field-name"
    values:
      label: "Full legal name"
      hint: "Enter your name as it appears on your ID."
      errors:
        required: "Enter your full legal name."
    rationale:
      rule_ids:
        - "uswds-forms.label-sentence-case"
      conflicts: []
      deviations: []
  - id: "field-description"
    values:
      label: "Description"
      hint: "Describe your situation briefly."
      errors: {}
    rationale:
      rule_ids:
        - "eighteen-f.voice-active"
      conflicts: []
      deviations: []
YAML
}

# ---------------------------------------------------------------------------
# Test 1: PASS — hard-constraint items identical, soft item identical
# ---------------------------------------------------------------------------
echo ""
echo "--- test 1: pass case — hard-constraint items identical ---"
_FIRST="$(mktemp "${TMPDIR:-/tmp}/coord-first.XXXXXX".yaml)"
_SECOND="$(mktemp "${TMPDIR:-/tmp}/coord-second.XXXXXX".yaml)"

write_first_pass "$_FIRST"
# Second pass: both items unchanged
cat > "$_SECOND" <<'YAML'
schema_version: 1
items:
  - id: "field-name"
    values:
      label: "Full legal name"
      hint: "Enter your name as it appears on your ID."
      errors:
        required: "Enter your full legal name."
    rationale:
      rule_ids:
        - "uswds-forms.label-sentence-case"
      conflicts: []
      deviations:
        - rule_id: "coordination-pass"
          reason: "IMMUTABLE — hard_constraint:true canon rule governs this item; values unchanged"
  - id: "field-description"
    values:
      label: "Description"
      hint: "Describe your situation briefly."
      errors: {}
    rationale:
      rule_ids:
        - "eighteen-f.voice-active"
      conflicts: []
      deviations: []
YAML

if bash "$DIFF_CHECK" "$_FIRST" "$_SECOND" >/dev/null 2>&1; then
  pass "hard-constraint items identical → diff-check exits 0"
else
  fail "hard-constraint items identical → diff-check unexpectedly rejected (exit non-zero)"
fi

rm -f "$_FIRST" "$_SECOND"

# ---------------------------------------------------------------------------
# Test 2: FAIL — hard-constraint item values.label changed → diff-check rejects
# ---------------------------------------------------------------------------
echo ""
echo "--- test 2: fail case — hard-constraint item values.label mutated ---"
_FIRST="$(mktemp "${TMPDIR:-/tmp}/coord-first.XXXXXX".yaml)"
_SECOND="$(mktemp "${TMPDIR:-/tmp}/coord-second.XXXXXX".yaml)"

write_first_pass "$_FIRST"
# Second pass: hard-constraint item 'field-name' has label changed
cat > "$_SECOND" <<'YAML'
schema_version: 1
items:
  - id: "field-name"
    values:
      label: "Legal Full Name"
      hint: "Enter your name as it appears on your ID."
      errors:
        required: "Enter your full legal name."
    rationale:
      rule_ids:
        - "uswds-forms.label-sentence-case"
      conflicts: []
      deviations: []
  - id: "field-description"
    values:
      label: "Description"
      hint: "Describe your situation briefly."
      errors: {}
    rationale:
      rule_ids:
        - "eighteen-f.voice-active"
      conflicts: []
      deviations: []
YAML

_STDERR_OUT="$(mktemp "${TMPDIR:-/tmp}/coord-stderr.XXXXXX".txt)"
if bash "$DIFF_CHECK" "$_FIRST" "$_SECOND" >/dev/null 2>"$_STDERR_OUT"; then
  fail "hard-constraint item.label mutated → diff-check should exit non-zero but exited 0"
else
  pass "hard-constraint item.label mutated → diff-check correctly exits non-zero"
fi

# Verify diagnostic names the offending item and canon rule_id
if grep -q "field-name" "$_STDERR_OUT"; then
  pass "diagnostic names the offending stable_id (field-name)"
else
  fail "diagnostic does not name the offending stable_id; stderr: $(cat "$_STDERR_OUT")"
fi

if grep -q "uswds-forms" "$_STDERR_OUT"; then
  pass "diagnostic names the offending canon rule_id (uswds-forms.*)"
else
  fail "diagnostic does not name the canon rule_id; stderr: $(cat "$_STDERR_OUT")"
fi

rm -f "$_FIRST" "$_SECOND" "$_STDERR_OUT"

# ---------------------------------------------------------------------------
# Test 3: PASS — only non-hard-constraint item changed → diff-check accepts
# ---------------------------------------------------------------------------
echo ""
echo "--- test 3: pass case — only soft (non-hard-constraint) item mutated ---"
_FIRST="$(mktemp "${TMPDIR:-/tmp}/coord-first.XXXXXX".yaml)"
_SECOND="$(mktemp "${TMPDIR:-/tmp}/coord-second.XXXXXX".yaml)"

write_first_pass "$_FIRST"
# Second pass: hard-constraint item 'field-name' is UNCHANGED; soft item 'field-description'
# has its label and hint changed (voice consistency revision).
cat > "$_SECOND" <<'YAML'
schema_version: 1
items:
  - id: "field-name"
    values:
      label: "Full legal name"
      hint: "Enter your name as it appears on your ID."
      errors:
        required: "Enter your full legal name."
    rationale:
      rule_ids:
        - "uswds-forms.label-sentence-case"
      conflicts: []
      deviations:
        - rule_id: "coordination-pass"
          reason: "IMMUTABLE — hard_constraint:true canon rule governs this item; values unchanged"
  - id: "field-description"
    values:
      label: "Your situation"
      hint: "Tell us about your situation in your own words."
      errors: {}
    rationale:
      rule_ids:
        - "eighteen-f.voice-active"
      conflicts: []
      deviations:
        - rule_id: "coordination-pass"
          reason: "Revised label and hint for cross-page voice consistency."
YAML

if bash "$DIFF_CHECK" "$_FIRST" "$_SECOND" >/dev/null 2>&1; then
  pass "only soft item mutated → diff-check exits 0 (accepted)"
else
  fail "only soft item mutated → diff-check unexpectedly rejected (exit non-zero)"
fi

rm -f "$_FIRST" "$_SECOND"

# ---------------------------------------------------------------------------
# Test 4: FAIL — hard-constraint item values.errors mutated → rejected
# ---------------------------------------------------------------------------
echo ""
echo "--- test 4: fail case — hard-constraint item values.errors mutated ---"
_FIRST="$(mktemp "${TMPDIR:-/tmp}/coord-first.XXXXXX".yaml)"
_SECOND="$(mktemp "${TMPDIR:-/tmp}/coord-second.XXXXXX".yaml)"

write_first_pass "$_FIRST"
# Second pass: hard-constraint item 'field-name' has errors.required changed
cat > "$_SECOND" <<'YAML'
schema_version: 1
items:
  - id: "field-name"
    values:
      label: "Full legal name"
      hint: "Enter your name as it appears on your ID."
      errors:
        required: "Please enter your full legal name."
    rationale:
      rule_ids:
        - "uswds-forms.label-sentence-case"
      conflicts: []
      deviations: []
  - id: "field-description"
    values:
      label: "Description"
      hint: "Describe your situation briefly."
      errors: {}
    rationale:
      rule_ids:
        - "eighteen-f.voice-active"
      conflicts: []
      deviations: []
YAML

if bash "$DIFF_CHECK" "$_FIRST" "$_SECOND" >/dev/null 2>&1; then
  fail "hard-constraint item.errors mutated → diff-check should exit non-zero but exited 0"
else
  pass "hard-constraint item.errors mutated → diff-check correctly exits non-zero"
fi

rm -f "$_FIRST" "$_SECOND"

# ---------------------------------------------------------------------------
# Test 5: PASS — govuk (hard_constraint=true) item identical
# ---------------------------------------------------------------------------
echo ""
echo "--- test 5: pass case — govuk hard-constraint item identical ---"
_FIRST="$(mktemp "${TMPDIR:-/tmp}/coord-first.XXXXXX".yaml)"
_SECOND="$(mktemp "${TMPDIR:-/tmp}/coord-second.XXXXXX".yaml)"

cat > "$_FIRST" <<'YAML'
schema_version: 1
items:
  - id: "error-summary"
    values:
      label: "There is a problem"
      hint: ""
      errors:
        generic: "Check the highlighted fields and try again."
    rationale:
      rule_ids:
        - "govuk.error-summary-title"
      conflicts: []
      deviations: []
YAML

# Identical in second pass
cat > "$_SECOND" <<'YAML'
schema_version: 1
items:
  - id: "error-summary"
    values:
      label: "There is a problem"
      hint: ""
      errors:
        generic: "Check the highlighted fields and try again."
    rationale:
      rule_ids:
        - "govuk.error-summary-title"
      conflicts: []
      deviations:
        - rule_id: "coordination-pass"
          reason: "IMMUTABLE — hard_constraint:true canon rule governs this item; values unchanged"
YAML

if bash "$DIFF_CHECK" "$_FIRST" "$_SECOND" >/dev/null 2>&1; then
  pass "govuk hard-constraint item identical → diff-check exits 0"
else
  fail "govuk hard-constraint item identical → diff-check unexpectedly rejected"
fi

rm -f "$_FIRST" "$_SECOND"

# ---------------------------------------------------------------------------
# Test 6: usage error — missing arguments → exit 2
# ---------------------------------------------------------------------------
echo ""
echo "--- test 6: usage error — missing arguments exits 2 ---"
_EXIT_CODE=0
bash "$DIFF_CHECK" >/dev/null 2>&1 || _EXIT_CODE=$?
if [[ "$_EXIT_CODE" -eq 2 ]]; then
  pass "missing arguments exits with code 2"
else
  fail "missing arguments should exit 2 but exited $_EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
