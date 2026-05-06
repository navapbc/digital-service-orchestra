#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

test_decision_id_contract_has_required_sections() {
  local f="$REPO_ROOT/plugins/dso/docs/contracts/decision-id-format.md"
  if test -f "$f"; then actual_exists="present"; else actual_exists="missing"; fi
  assert_eq "decision-id-format.md exists" "present" "$actual_exists"
  if grep -q '^## Signal Name' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Signal Name section" "present" "$actual"
  if grep -q '^## Format' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Format section" "present" "$actual"
  if grep -q '^## Emitter' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Emitter section" "present" "$actual"
  if grep -q '^## Parser' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Parser section" "present" "$actual"
}

test_inference_envelope_contract_has_required_sections() {
  local f="$REPO_ROOT/plugins/dso/docs/contracts/inference-envelope.md"
  if test -f "$f"; then actual_exists="present"; else actual_exists="missing"; fi
  assert_eq "inference-envelope.md exists" "present" "$actual_exists"
  if grep -q '^## Signal Name' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Signal Name section" "present" "$actual"
  if grep -q '^## Status' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Status section" "present" "$actual"
  if grep -q '^## Format' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Format section" "present" "$actual"
  if grep -q '^## Emitter' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Emitter section" "present" "$actual"
  if grep -q '^## Parser' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Parser section" "present" "$actual"
}

test_meta_question_signal_contract_has_required_sections() {
  local f="$REPO_ROOT/plugins/dso/docs/contracts/meta-question-signal.md"
  if test -f "$f"; then actual_exists="present"; else actual_exists="missing"; fi
  assert_eq "meta-question-signal.md exists" "present" "$actual_exists"
  if grep -q '^## Signal Name' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Signal Name section" "present" "$actual"
  if grep -q '^## Status' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Status section" "present" "$actual"
  if grep -q '^## Format' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Format section" "present" "$actual"
  if grep -q '^## Emitter' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Emitter section" "present" "$actual"
  if grep -q '^## Parser' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Parser section" "present" "$actual"
}

test_inference_incident_schema_contract_has_required_sections() {
  local f="$REPO_ROOT/plugins/dso/docs/contracts/inference-incident-schema.md"
  if test -f "$f"; then actual_exists="present"; else actual_exists="missing"; fi
  assert_eq "inference-incident-schema.md exists" "present" "$actual_exists"
  if grep -q '^## Signal Name' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Signal Name section" "present" "$actual"
  if grep -q '^## Status' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Status section" "present" "$actual"
  if grep -q '^## Schema' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Schema section" "present" "$actual"
  if grep -q '^## Format' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Format section" "present" "$actual"
  if grep -q '^## Emitter' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Emitter section" "present" "$actual"
  if grep -q '^## Parser' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has Parser section" "present" "$actual"
}

test_decision_id_contract_has_required_sections
test_inference_envelope_contract_has_required_sections
test_meta_question_signal_contract_has_required_sections
test_inference_incident_schema_contract_has_required_sections
print_summary
