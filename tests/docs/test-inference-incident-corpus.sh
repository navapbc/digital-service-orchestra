#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

test_corpus_file_has_minimum_incidents() {
  local f="$REPO_ROOT/tests/fixtures/inference-incidents/incidents.jsonl"
  if test -f "$f"; then actual_exists="present"; else actual_exists="missing"; fi
  assert_eq "incidents.jsonl exists" "present" "$actual_exists"
  local count
  count=$(jq -s 'length' "$f" 2>/dev/null || echo 0)
  if [ "$count" -ge 20 ]; then actual="sufficient"; else actual="insufficient"; fi
  assert_eq "at least 20 incidents" "sufficient" "$actual"
}

test_corpus_ticket_ids_match_format() {
  local f="$REPO_ROOT/tests/fixtures/inference-incidents/incidents.jsonl"
  if test -f "$f"; then actual_exists="present"; else actual_exists="missing"; fi
  assert_eq "incidents.jsonl exists" "present" "$actual_exists"
  local invalid
  invalid=$(jq -rs '.[].ticket_id' "$f" 2>/dev/null | { grep -cv '^[a-z0-9]\{4\}-[a-z0-9]\{4\}$' || true; })
  assert_eq "all ticket_ids match 4-4 hex format" "0" "$invalid"
}

test_holdout_file_exists() {
  local f="$REPO_ROOT/tests/fixtures/inference-incidents/holdout.txt"
  if test -f "$f"; then actual="present"; else actual="missing"; fi
  assert_eq "holdout.txt exists" "present" "$actual"
}

test_holdout_entries_match_corpus_subset() {
  local corpus="$REPO_ROOT/tests/fixtures/inference-incidents/incidents.jsonl"
  local holdout="$REPO_ROOT/tests/fixtures/inference-incidents/holdout.txt"
  if [[ -f "$corpus" && -f "$holdout" ]]; then actual="present"; else actual="missing"; fi
  assert_eq "both files exist" "present" "$actual"
  # Pre-extract corpus ids once to avoid repeated jq passes
  local corpus_ids
  corpus_ids=$(jq -rs '.[].ticket_id' "$corpus" 2>/dev/null || echo "")
  while IFS= read -r tid; do
    [[ "$tid" =~ ^# ]] && continue
    [[ -z "$tid" ]] && continue
    local found
    found=$(printf '%s\n' "$corpus_ids" | grep -c "^${tid}$" || echo 0)
    assert_eq "holdout $tid in corpus" "1" "$found"
  done < "$holdout"
}

test_holdout_is_non_empty_subset() {
  local corpus="$REPO_ROOT/tests/fixtures/inference-incidents/incidents.jsonl"
  local holdout="$REPO_ROOT/tests/fixtures/inference-incidents/holdout.txt"
  if [[ -f "$corpus" && -f "$holdout" ]]; then actual="present"; else actual="missing"; fi
  assert_eq "both files exist" "present" "$actual"
  local line_count
  line_count=$(grep -c '.' "$holdout" 2>/dev/null || echo 0)
  if [ "$line_count" -gt 0 ]; then actual="non-empty"; else actual="empty"; fi
  assert_eq "holdout.txt is non-empty" "non-empty" "$actual"
}

test_corpus_file_has_minimum_incidents
test_corpus_ticket_ids_match_format
test_holdout_file_exists
test_holdout_entries_match_corpus_subset
test_holdout_is_non_empty_subset
print_summary
