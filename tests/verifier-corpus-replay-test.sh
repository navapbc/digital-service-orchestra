#!/usr/bin/env bash
# tests/verifier-corpus-replay-test.sh
# RED structural tests for verifier regression fixture corpus.
# Testing Mode: RED — replay harness (T2) not yet created so functional replay fails

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/assert.sh"

CORPUS_DIR="$SCRIPT_DIR/fixtures/verifier-corpus"

# test_corpus_fixture_ee3a_exists
echo "--- test_corpus_fixture_ee3a_exists ---"
_snapshot_fail
test -f "$CORPUS_DIR/ee3a-43fc/diff.patch" && \
  test -f "$CORPUS_DIR/ee3a-43fc/finding.json" && \
  test -f "$CORPUS_DIR/ee3a-43fc/expected_ruling.json"
assert_eq "test_corpus_fixture_ee3a_exists" "0" "$?"
assert_pass_if_clean "test_corpus_fixture_ee3a_exists"

# test_corpus_fixture_b2ef_exists
echo "--- test_corpus_fixture_b2ef_exists ---"
_snapshot_fail
test -f "$CORPUS_DIR/b2ef-cd72/diff.patch" && \
  test -f "$CORPUS_DIR/b2ef-cd72/finding.json" && \
  test -f "$CORPUS_DIR/b2ef-cd72/expected_ruling.json"
assert_eq "test_corpus_fixture_b2ef_exists" "0" "$?"
assert_pass_if_clean "test_corpus_fixture_b2ef_exists"

# test_corpus_fixture_9e84_exists
echo "--- test_corpus_fixture_9e84_exists ---"
_snapshot_fail
test -f "$CORPUS_DIR/9e84-2b78/diff.patch" && \
  test -f "$CORPUS_DIR/9e84-2b78/finding.json" && \
  test -f "$CORPUS_DIR/9e84-2b78/expected_ruling.json"
assert_eq "test_corpus_fixture_9e84_exists" "0" "$?"
assert_pass_if_clean "test_corpus_fixture_9e84_exists"

# test_expected_ruling_drop_for_ee3a
echo "--- test_expected_ruling_drop_for_ee3a ---"
_snapshot_fail
python3 -c "
import json, sys
with open('$CORPUS_DIR/ee3a-43fc/expected_ruling.json') as f:
    d = json.load(f)
assert d['ruling'] == 'drop', f'Expected drop, got {d[\"ruling\"]}'
" 2>/dev/null
assert_eq "test_expected_ruling_drop_for_ee3a" "0" "$?"
assert_pass_if_clean "test_expected_ruling_drop_for_ee3a"

# test_expected_ruling_downgrade_for_b2ef
echo "--- test_expected_ruling_downgrade_for_b2ef ---"
_snapshot_fail
python3 -c "
import json, sys
with open('$CORPUS_DIR/b2ef-cd72/expected_ruling.json') as f:
    d = json.load(f)
assert d['ruling'] == 'downgrade-to-minor', f'Expected downgrade-to-minor, got {d[\"ruling\"]}'
" 2>/dev/null
assert_eq "test_expected_ruling_downgrade_for_b2ef" "0" "$?"
assert_pass_if_clean "test_expected_ruling_downgrade_for_b2ef"

# test_replay_harness_exists (GREEN — T2 created plugins/dso/scripts/verifier-corpus-replay.sh)
echo "--- test_replay_harness_exists ---"
_snapshot_fail
test -f "$PLUGIN_ROOT/plugins/dso/scripts/verifier-corpus-replay.sh"
assert_eq "test_replay_harness_exists" "0" "$?"
assert_pass_if_clean "test_replay_harness_exists"

print_summary
