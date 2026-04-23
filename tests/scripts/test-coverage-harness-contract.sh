#!/usr/bin/env bash
# tests/scripts/test-coverage-harness-contract.sh
# Structural tests for plugins/dso/docs/contracts/coverage-harness-output.md
# Verifies the contract document contains required signal and field names.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTRACT="$REPO_ROOT/plugins/dso/docs/contracts/coverage-harness-output.md"

source "$REPO_ROOT/tests/lib/assert.sh"

test_contract_file_exists() {
    assert_eq "contract file exists" "true" "$( [[ -f "$CONTRACT" ]] && echo true || echo false )"
}

test_contract_contains_coverage_result_signal() {
    local found
    found=$(grep -c "COVERAGE_RESULT" "$CONTRACT" 2>/dev/null || echo 0)
    assert_ne "COVERAGE_RESULT signal present in contract" "0" "$found"
}

test_contract_contains_preventions_count_field() {
    local found
    found=$(grep -c "preventions_count" "$CONTRACT" 2>/dev/null || echo 0)
    assert_ne "preventions_count field present in contract" "0" "$found"
}

test_contract_contains_corpus_size_field() {
    local found
    found=$(grep -c "corpus_size" "$CONTRACT" 2>/dev/null || echo 0)
    assert_ne "corpus_size field present in contract" "0" "$found"
}

test_contract_contains_prevention_rate_field() {
    local found
    found=$(grep -c "prevention_rate" "$CONTRACT" 2>/dev/null || echo 0)
    assert_ne "prevention_rate field present in contract" "0" "$found"
}

test_contract_contains_threshold_field() {
    local found
    found=$(grep -c "threshold" "$CONTRACT" 2>/dev/null || echo 0)
    assert_ne "threshold field present in contract" "0" "$found"
}

test_contract_contains_emitter_reference() {
    local found
    found=$(grep -c "preconditions-coverage-harness.sh" "$CONTRACT" 2>/dev/null || echo 0)
    assert_ne "emitter script reference present in contract" "0" "$found"
}

test_contract_contains_sc9_gate_reference() {
    local found
    found=$(grep -c "SC9" "$CONTRACT" 2>/dev/null || echo 0)
    assert_ne "SC9 gate reference present in contract" "0" "$found"
}

test_contract_file_exists
test_contract_contains_coverage_result_signal
test_contract_contains_preventions_count_field
test_contract_contains_corpus_size_field
test_contract_contains_prevention_rate_field
test_contract_contains_threshold_field
test_contract_contains_emitter_reference
test_contract_contains_sc9_gate_reference

print_summary
