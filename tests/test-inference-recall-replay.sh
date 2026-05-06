#!/usr/bin/env bash
# tests/test-inference-recall-replay.sh
# RED tests for story 1c7b-74a6 (inference-recall-replay harness + RECALL_RESULT contract)
# Tasks: 3d32-d1be, 3b75-4262, bf54-67cb, e7dc-e592
# All tests FAIL until both the contract doc and harness script are created.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Task 3d32-d1be: Contract doc structural tests
# Target: plugins/dso/docs/contracts/inference-recall-result.md (doesn't exist yet)
# ---------------------------------------------------------------------------

test_recall_result_contract_exists() {
  local CONTRACT="$REPO_ROOT/plugins/dso/docs/contracts/inference-recall-result.md"
  local actual
  if test -f "$CONTRACT"; then actual=present; else actual=missing; fi
  assert_eq "inference-recall-result.md exists" "present" "$actual"
}

test_recall_result_has_signal_name_section() {
  local CONTRACT="$REPO_ROOT/plugins/dso/docs/contracts/inference-recall-result.md"
  local actual
  if test -f "$CONTRACT" && grep -q '^## Signal Name' "$CONTRACT"; then actual=present; else actual=missing; fi
  assert_eq "has ## Signal Name section" "present" "$actual"
}

test_recall_result_has_emitter_section() {
  local CONTRACT="$REPO_ROOT/plugins/dso/docs/contracts/inference-recall-result.md"
  local actual
  if test -f "$CONTRACT" && grep -q '^## Emitter' "$CONTRACT"; then actual=present; else actual=missing; fi
  assert_eq "has ## Emitter section" "present" "$actual"
}

test_recall_result_has_output_schema_section() {
  local CONTRACT="$REPO_ROOT/plugins/dso/docs/contracts/inference-recall-result.md"
  local actual
  if test -f "$CONTRACT" && grep -q '^## Output Schema' "$CONTRACT"; then actual=present; else actual=missing; fi
  assert_eq "has ## Output Schema section" "present" "$actual"
}

test_recall_result_has_sc4_gate_semantics_section() {
  local CONTRACT="$REPO_ROOT/plugins/dso/docs/contracts/inference-recall-result.md"
  local actual
  if test -f "$CONTRACT" && grep -q '^## SC4 Gate Semantics' "$CONTRACT"; then actual=present; else actual=missing; fi
  assert_eq "has ## SC4 Gate Semantics section" "present" "$actual"
}

# ---------------------------------------------------------------------------
# Task 3b75-4262: Metric computation tests
# Target: plugins/dso/scripts/inference-recall-replay.sh (doesn't exist yet)
# ---------------------------------------------------------------------------

test_recall_all_at_threshold() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-test.XXXXXX)
  # Create 10 synthetic incidents
  for i in $(seq 1 10); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"test inference %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"source %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  # Stub classifier: always returns "challenge"
  local stub="$tmpdir/stub-classifier.sh"
  printf '#!/usr/bin/env bash\necho "challenge"\n' > "$stub"
  chmod +x "$stub"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" CLASSIFIER_CMD="$stub" bash "$harness" 2>&1 || true)
  local actual
  if echo "$output" | grep -q 'RECALL_RESULT.*recall_all=1\.0'; then actual=pass; else actual=fail; fi
  assert_eq "recall_all=1.0 when all challenged" "pass" "$actual"
  rm -rf "$tmpdir"
}

test_recall_all_below_threshold_fails() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-test.XXXXXX)
  # Create 10 incidents
  for i in $(seq 1 10); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"test inference %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"source %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  # Stub classifier: challenges only 4 of 10 (those with id <= 4)
  local stub="$tmpdir/stub-classifier-partial.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
# Read ticket_id from stdin/args; challenge only first 4
id="${1:-}"
num=$(echo "$id" | grep -oE '[0-9]+$' || echo 99)
if [ "$num" -le 4 ] 2>/dev/null; then echo "challenge"; else echo "skip"; fi
STUB
  chmod +x "$stub"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local rc=0
  INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" CLASSIFIER_CMD="$stub" bash "$harness" 2>&1 || rc=$?
  assert_eq "exits non-zero when recall_all=0.4 < 0.5" "1" "$([ $rc -ne 0 ] && echo 1 || echo 0)"
  rm -rf "$tmpdir"
}

test_recall_holdout_threshold() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-test.XXXXXX)
  # Create 10 incidents; 3 are in holdout subset
  for i in $(seq 1 10); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"holdout test %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"source %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  # Mark tickets 1-3 as holdout
  printf 'test-%04x\ntest-%04x\ntest-%04x\n' 1 2 3 > "$tmpdir/holdout.txt"
  # Stub classifier: challenge all
  local stub="$tmpdir/stub-all.sh"
  printf '#!/usr/bin/env bash\necho "challenge"\n' > "$stub"
  chmod +x "$stub"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" CLASSIFIER_CMD="$stub" bash "$harness" 2>&1 || true)
  local actual
  if echo "$output" | grep -q 'RECALL_RESULT.*recall_holdout=1\.0'; then actual=pass; else actual=fail; fi
  assert_eq "recall_holdout=1.0 when all holdout incidents challenged" "pass" "$actual"
  rm -rf "$tmpdir"
}

test_precision_at_threshold() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-test.XXXXXX)
  # 5 real incidents (outcome=user_corrected) + 3 non-incidents (outcome=accepted)
  for i in $(seq 1 5); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"real %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  for i in $(seq 6 8); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"false %d","affects_fields":"description","outcome":"accepted","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  # Stub classifier: challenge all 8 → precision = 5/8 = 0.625 ≥ 0.5 → PASS
  local stub="$tmpdir/stub-all.sh"
  printf '#!/usr/bin/env bash\necho "challenge"\n' > "$stub"
  chmod +x "$stub"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" CLASSIFIER_CMD="$stub" bash "$harness" 2>&1 || true)
  local actual
  if echo "$output" | grep -q 'RECALL_RESULT.*precision=0\.6'; then actual=pass; else actual=fail; fi
  assert_eq "precision≥0.5 emits PASS signal" "pass" "$actual"
  rm -rf "$tmpdir"
}

test_precision_below_threshold_fails() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-test.XXXXXX)
  # 4 real incidents + 6 non-incidents; challenge all 10 → precision = 4/10 = 0.4 < 0.5
  for i in $(seq 1 4); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"real %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  for i in $(seq 5 10); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"false %d","affects_fields":"description","outcome":"accepted","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  local stub="$tmpdir/stub-all.sh"
  printf '#!/usr/bin/env bash\necho "challenge"\n' > "$stub"
  chmod +x "$stub"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local rc=0
  INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" CLASSIFIER_CMD="$stub" bash "$harness" 2>&1 || rc=$?
  assert_eq "exits non-zero when precision=0.4 < 0.5" "1" "$([ $rc -ne 0 ] && echo 1 || echo 0)"
  rm -rf "$tmpdir"
}

test_recall_result_signal_in_stdout() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-test.XXXXXX)
  for i in $(seq 1 10); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"test %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  local stub="$tmpdir/stub-all.sh"
  printf '#!/usr/bin/env bash\necho "challenge"\n' > "$stub"
  chmod +x "$stub"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" CLASSIFIER_CMD="$stub" bash "$harness" 2>&1 || true)
  local actual
  if echo "$output" | grep -q 'RECALL_RESULT'; then actual=present; else actual=missing; fi
  assert_eq "RECALL_RESULT signal emitted on successful run" "present" "$actual"
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Task bf54-67cb: Corpus quality check tests
# ---------------------------------------------------------------------------

test_valid_corpus_no_exclusions() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-cq.XXXXXX)
  # All 10 incidents have valid ticket_ids (test-* → stub exits 0)
  for i in $(seq 1 10); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"valid %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  local stub_classifier="$tmpdir/stub-all.sh"
  printf '#!/usr/bin/env bash\necho "challenge"\n' > "$stub_classifier"
  chmod +x "$stub_classifier"
  local stub_ticket="$tmpdir/ticket-exists.sh"
  cat > "$stub_ticket" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in test-*) exit 0;; *) exit 1;; esac
STUBEOF
  chmod +x "$stub_ticket"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" \
    CLASSIFIER_CMD="$stub_classifier" TICKET_EXISTS_CMD="$stub_ticket" \
    bash "$harness" 2>&1 || true)
  local actual
  if echo "$output" | grep -q 'CORPUS_QUALITY_WARNING'; then actual=present; else actual=missing; fi
  assert_eq "no CORPUS_QUALITY_WARNING when all tickets valid" "missing" "$actual"
  rm -rf "$tmpdir"
}

test_invalid_ticket_ids_excluded_with_warning() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-cq.XXXXXX)
  # 10 valid + 2 invalid ticket_ids
  for i in $(seq 1 10); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"valid %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  for i in $(seq 1 2); do
    printf '{"ticket_id":"invalid-%04x","inferred_decision_text":"bad %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  local stub_classifier="$tmpdir/stub-all.sh"
  printf '#!/usr/bin/env bash\necho "challenge"\n' > "$stub_classifier"
  chmod +x "$stub_classifier"
  # ticket-exists stub: test-* valid, invalid-* not valid
  local stub_ticket="$tmpdir/ticket-exists.sh"
  cat > "$stub_ticket" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in test-*) exit 0;; *) exit 1;; esac
STUBEOF
  chmod +x "$stub_ticket"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" \
    CLASSIFIER_CMD="$stub_classifier" TICKET_EXISTS_CMD="$stub_ticket" \
    bash "$harness" 2>&1 || true)
  local actual
  if echo "$output" | grep -q 'CORPUS_QUALITY_WARNING'; then actual=present; else actual=missing; fi
  assert_eq "CORPUS_QUALITY_WARNING emitted for 2 invalid ticket_ids" "present" "$actual"
  rm -rf "$tmpdir"
}

test_tiny_corpus_after_exclusion_emits_corpus_insufficient() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-cq.XXXXXX)
  # 8 valid + 3 invalid; after exclusion only 8 remain → < 10 → CORPUS_INSUFFICIENT
  for i in $(seq 1 8); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"valid %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  for i in $(seq 1 3); do
    printf '{"ticket_id":"bad-%04x","inferred_decision_text":"bad %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  local stub_classifier="$tmpdir/stub-all.sh"
  printf '#!/usr/bin/env bash\necho "challenge"\n' > "$stub_classifier"
  chmod +x "$stub_classifier"
  local stub_ticket="$tmpdir/ticket-exists.sh"
  cat > "$stub_ticket" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in test-*) exit 0;; *) exit 1;; esac
STUBEOF
  chmod +x "$stub_ticket"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" \
    CLASSIFIER_CMD="$stub_classifier" TICKET_EXISTS_CMD="$stub_ticket" \
    bash "$harness" 2>&1 || true)
  local actual
  if echo "$output" | grep -q 'CORPUS_INSUFFICIENT'; then actual=present; else actual=missing; fi
  assert_eq "CORPUS_INSUFFICIENT emitted when <10 valid incidents remain" "present" "$actual"
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Task e7dc-e592: CORPUS_INSUFFICIENT tests
# ---------------------------------------------------------------------------

test_empty_corpus_emits_corpus_insufficient() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-ci.XXXXXX)
  # Empty corpus
  touch "$tmpdir/incidents.jsonl"
  touch "$tmpdir/holdout.txt"
  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local rc=0
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" bash "$harness" 2>&1) || rc=$?
  local actual
  if echo "$output" | grep -q 'CORPUS_INSUFFICIENT'; then actual=present; else actual=missing; fi
  assert_eq "CORPUS_INSUFFICIENT emitted for empty corpus" "present" "$actual"
  assert_eq "exits non-zero for empty corpus" "1" "$([ $rc -ne 0 ] && echo 1 || echo 0)"
  rm -rf "$tmpdir"
}

test_nine_incidents_corpus_insufficient() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-ci.XXXXXX)
  # 9 incidents — below minimum of 10
  for i in $(seq 1 9); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"test %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local rc=0
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" bash "$harness" 2>&1) || rc=$?
  local actual
  if echo "$output" | grep -q 'CORPUS_INSUFFICIENT'; then actual=present; else actual=missing; fi
  assert_eq "CORPUS_INSUFFICIENT emitted for 9 incidents" "present" "$actual"
  assert_eq "exits non-zero for 9 incidents" "1" "$([ $rc -ne 0 ] && echo 1 || echo 0)"
  rm -rf "$tmpdir"
}

test_ten_incidents_no_corpus_insufficient() {
  local tmpdir; tmpdir=$(mktemp -d /tmp/recall-ci.XXXXXX)
  # Exactly 10 incidents — meets minimum threshold
  for i in $(seq 1 10); do
    printf '{"ticket_id":"test-%04x","inferred_decision_text":"test %d","affects_fields":"description","outcome":"user_corrected","source_decision_text":"src %d"}\n' \
      "$i" "$i" "$i" >> "$tmpdir/incidents.jsonl"
  done
  touch "$tmpdir/holdout.txt"
  local stub="$tmpdir/stub-all.sh"
  printf '#!/usr/bin/env bash\necho "challenge"\n' > "$stub"
  chmod +x "$stub"

  local harness="$REPO_ROOT/plugins/dso/scripts/inference-recall-replay.sh"
  if ! test -f "$harness"; then
    assert_eq "harness exists" "present" "missing"
    rm -rf "$tmpdir"
    return
  fi
  local output
  output=$(INCIDENTS_FILE="$tmpdir/incidents.jsonl" HOLDOUT_FILE="$tmpdir/holdout.txt" CLASSIFIER_CMD="$stub" bash "$harness" 2>&1 || true)
  local actual
  if echo "$output" | grep -q 'CORPUS_INSUFFICIENT'; then actual=present; else actual=missing; fi
  assert_eq "no CORPUS_INSUFFICIENT for exactly 10 incidents" "missing" "$actual"
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_recall_result_contract_exists
test_recall_result_has_signal_name_section
test_recall_result_has_emitter_section
test_recall_result_has_output_schema_section
test_recall_result_has_sc4_gate_semantics_section

test_recall_all_at_threshold
test_recall_all_below_threshold_fails
test_recall_holdout_threshold
test_precision_at_threshold
test_precision_below_threshold_fails
test_recall_result_signal_in_stdout

test_valid_corpus_no_exclusions
test_invalid_ticket_ids_excluded_with_warning
test_tiny_corpus_after_exclusion_emits_corpus_insufficient

test_empty_corpus_emits_corpus_insufficient
test_nine_incidents_corpus_insufficient
test_ten_incidents_no_corpus_insufficient

print_summary
