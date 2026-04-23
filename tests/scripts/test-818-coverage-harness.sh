#!/usr/bin/env bash
# tests/scripts/test-818-coverage-harness.sh
# RED tests for plugins/dso/scripts/preconditions-coverage-harness.sh
# These tests fail RED until preconditions-coverage-harness.sh is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="$REPO_ROOT/plugins/dso/scripts/preconditions-coverage-harness.sh"
DEFAULT_CORPUS="$REPO_ROOT/tests/fixtures/818-corpus/sample-bugs.json"

source "$REPO_ROOT/tests/lib/assert.sh"

test_coverage_harness_counts_preventions() {
    # RED: preconditions-coverage-harness.sh does not exist yet
    if [[ ! -f "$HARNESS" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: preconditions-coverage-harness.sh to exist at %s\n  actual:   file not found\n" \
            "coverage_harness_counts_preventions" "$HARNESS" >&2
        return
    fi

    # Use the default corpus if it exists, else a temp minimal one
    local corpus_path="$DEFAULT_CORPUS"
    local tmpdir=""
    if [[ ! -f "$corpus_path" ]]; then
        tmpdir=$(mktemp -d)
        corpus_path="$tmpdir/sample-bugs.json"
        # Minimal corpus for test
        python3 -c "
import json
bugs = [{'id': f'bug-{i:03d}', 'description': f'Test bug {i}', 'type': 'logic', 'severity': 'high'} for i in range(1, 11)]
print(json.dumps(bugs))
" > "$corpus_path"
    fi

    local output
    output=$(bash "$HARNESS" --corpus "$corpus_path" --dry-run --output json 2>/dev/null)
    local exit_code=$?
    assert_eq "coverage harness exits 0" "0" "$exit_code"

    # Output must contain COVERAGE_RESULT signal
    local has_signal
    has_signal=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('yes' if data.get('signal') == 'COVERAGE_RESULT' else 'no')
" 2>/dev/null || echo "parse-error")
    assert_eq "output contains COVERAGE_RESULT signal" "yes" "$has_signal"

    # preventions_count must be present and non-negative
    local preventions_count
    preventions_count=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
pc = data.get('preventions_count')
print('valid' if isinstance(pc, int) and pc >= 0 else f'invalid:{pc}')
" 2>/dev/null || echo "parse-error")
    assert_eq "preventions_count is a non-negative integer" "valid" "$preventions_count"

    [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
}

test_coverage_result_meets_threshold() {
    # RED: preconditions-coverage-harness.sh does not exist yet
    if [[ ! -f "$HARNESS" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: preconditions-coverage-harness.sh to exist at %s\n  actual:   file not found\n" \
            "coverage_result_meets_threshold" "$HARNESS" >&2
        return
    fi

    # This test only runs meaningfully when the default corpus has ≥100 records
    if [[ ! -f "$DEFAULT_CORPUS" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: sample-bugs.json at %s\n  actual:   file not found\n" \
            "coverage_result_meets_threshold" "$DEFAULT_CORPUS" >&2
        return
    fi

    local corpus_size
    corpus_size=$(python3 -c "import json; data=json.load(open('$DEFAULT_CORPUS')); print(len(data))" 2>/dev/null || echo 0)
    if [[ "$corpus_size" -lt 100 ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: corpus size >= 100\n  actual:   %s\n" \
            "coverage_result_meets_threshold" "$corpus_size" >&2
        return
    fi

    local output
    output=$(bash "$HARNESS" --corpus "$DEFAULT_CORPUS" --dry-run --output json 2>/dev/null)

    local preventions_count
    preventions_count=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('preventions_count', -1))
" 2>/dev/null || echo "-1")

    local threshold=100
    local meets_threshold
    meets_threshold=$(python3 -c "
try:
    pc = int('$preventions_count')
    print('yes' if pc >= $threshold else f'no: {pc} < $threshold')
except:
    print('no: parse error')
" 2>/dev/null || echo "no")
    assert_eq "preventions_count >= 100" "yes" "$meets_threshold"
}

test_coverage_harness_counts_preventions
test_coverage_result_meets_threshold

print_summary
