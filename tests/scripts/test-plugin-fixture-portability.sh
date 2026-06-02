#!/usr/bin/env bash
# tests/scripts/test-plugin-fixture-portability.sh
# Verifies that fixture files required by plugin scripts are present at their
# plugin-relative paths (plugins/dso/data/fixtures/...) and NOT only under
# tests/fixtures/, which is not shipped in the distributed plugin cache.
#
# Bug: 3bda-755d-c938-4e62 — Plugin scripts reference tests/fixtures paths not
# shipped in plugin cache.
#
# Tests:
#  (1) test_inference_incidents_fixtures_in_plugin    — incidents.jsonl + holdout.txt under data/fixtures/
#  (2) test_818_corpus_fixture_in_plugin              — sample-bugs.json under data/fixtures/
#  (3) test_dogfood_fixtures_in_plugin                — bad-copy-baseline.yaml + good-copy-improved.yaml under data/fixtures/
#  (4) test_inference_replay_default_uses_plugin_root — script default INCIDENTS_FILE references _PLUGIN_ROOT, not tests/
#  (5) test_preconditions_harness_default_corpus      — _DEFAULT_CORPUS references _PLUGIN_ROOT, not _REPO_ROOT/tests/
#  (6) test_dogfood_default_paths_use_data_fixtures   — BASELINE/IMPROVED reference data/fixtures/, not tests/
#
# Usage: bash tests/scripts/test-plugin-fixture-portability.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/plugins/dso"
DATA_FIXTURES="$PLUGIN_ROOT/data/fixtures"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-plugin-fixture-portability.sh ==="

# ── Test 1: inference-incidents fixtures present under plugins/dso/data/fixtures ──
_snapshot_fail
if [[ ! -f "$DATA_FIXTURES/inference-incidents/incidents.jsonl" ]]; then
    echo "MISSING: $DATA_FIXTURES/inference-incidents/incidents.jsonl" >&2; (( ++FAIL ))
fi
if [[ ! -f "$DATA_FIXTURES/inference-incidents/holdout.txt" ]]; then
    echo "MISSING: $DATA_FIXTURES/inference-incidents/holdout.txt" >&2; (( ++FAIL ))
fi
# incidents.jsonl must be valid JSONL
_bad_lines=0
while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ -z "$_line" ]] && continue
    printf '%s' "$_line" | jq empty 2>/dev/null || _bad_lines=$(( _bad_lines + 1 ))
done < "$DATA_FIXTURES/inference-incidents/incidents.jsonl"
assert_eq "incidents.jsonl parses as valid JSONL" "0" "$_bad_lines"
assert_pass_if_clean "test_inference_incidents_fixtures_in_plugin"

# ── Test 2: 818-corpus fixture present under plugins/dso/data/fixtures ──
_snapshot_fail
if [[ ! -f "$DATA_FIXTURES/818-corpus/sample-bugs.json" ]]; then
    echo "MISSING: $DATA_FIXTURES/818-corpus/sample-bugs.json" >&2; (( ++FAIL ))
fi
_is_array=$(jq -r 'if type == "array" then "yes" else "no" end' \
    "$DATA_FIXTURES/818-corpus/sample-bugs.json" 2>/dev/null || echo "no")
assert_eq "sample-bugs.json is a JSON array" "yes" "$_is_array"
assert_pass_if_clean "test_818_corpus_fixture_in_plugin"

# ── Test 3: dogfood fixtures present under plugins/dso/data/fixtures ──
_snapshot_fail
if [[ ! -f "$DATA_FIXTURES/dogfood/bad-copy-baseline.yaml" ]]; then
    echo "MISSING: $DATA_FIXTURES/dogfood/bad-copy-baseline.yaml" >&2; (( ++FAIL ))
fi
if [[ ! -f "$DATA_FIXTURES/dogfood/good-copy-improved.yaml" ]]; then
    echo "MISSING: $DATA_FIXTURES/dogfood/good-copy-improved.yaml" >&2; (( ++FAIL ))
fi
assert_pass_if_clean "test_dogfood_fixtures_in_plugin"

# ── Test 4: inference-recall-replay.sh defaults reference _PLUGIN_ROOT, not bare tests/ ──
_script="$PLUGIN_ROOT/scripts/inference-recall-replay.sh"
# Must NOT have bare tests/fixtures/ in the default variable assignments
_bare_ref=$(grep -E "^INCIDENTS_FILE=|^HOLDOUT_FILE=" "$_script" | grep "tests/fixtures" || echo "")
assert_eq "inference-recall-replay.sh defaults must not reference bare tests/fixtures/" \
    "" "$_bare_ref"
# Must reference _PLUGIN_ROOT in defaults
_plugin_ref=$(grep -E "^INCIDENTS_FILE=|^HOLDOUT_FILE=" "$_script" | grep "_PLUGIN_ROOT" || echo "")
assert_ne "inference-recall-replay.sh defaults must reference \${_PLUGIN_ROOT}/data/fixtures/" \
    "" "$_plugin_ref"

# ── Test 5: preconditions-coverage-harness.sh _DEFAULT_CORPUS references _PLUGIN_ROOT ──
_script="$PLUGIN_ROOT/scripts/preconditions-coverage-harness.sh"
# Must NOT reference _REPO_ROOT/tests/fixtures for default corpus
_repo_ref=$(grep "_DEFAULT_CORPUS" "$_script" | grep "_REPO_ROOT/tests/fixtures" || echo "")
assert_eq "preconditions-coverage-harness.sh _DEFAULT_CORPUS must not reference \$_REPO_ROOT/tests/fixtures/" \
    "" "$_repo_ref"
# Must reference _PLUGIN_ROOT/data/fixtures
_plugin_ref=$(grep "_DEFAULT_CORPUS" "$_script" | grep "_PLUGIN_ROOT" || echo "")
assert_ne "preconditions-coverage-harness.sh _DEFAULT_CORPUS must reference \${_PLUGIN_ROOT}/data/fixtures/" \
    "" "$_plugin_ref"

# ── Test 6: dogfood-gov-copy.sh BASELINE/IMPROVED reference data/fixtures/ ──
_script="$PLUGIN_ROOT/scripts/dogfood-gov-copy.sh"
# Must NOT reference tests/fixtures in BASELINE/IMPROVED defaults
_tests_ref=$(grep -E "^BASELINE=|^IMPROVED=" "$_script" | grep "tests/fixtures" || echo "")
assert_eq "dogfood-gov-copy.sh BASELINE/IMPROVED must not reference tests/fixtures/" \
    "" "$_tests_ref"
# Must reference data/fixtures/
_data_ref=$(grep -E "^BASELINE=|^IMPROVED=" "$_script" | grep "data/fixtures" || echo "")
assert_ne "dogfood-gov-copy.sh BASELINE/IMPROVED must reference data/fixtures/" \
    "" "$_data_ref"

print_summary
