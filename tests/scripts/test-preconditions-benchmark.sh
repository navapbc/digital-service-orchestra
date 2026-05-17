#!/usr/bin/env bash
# tests/scripts/test-preconditions-benchmark.sh
# Structural tests for plugins/dso/scripts/preconditions-benchmark.sh
#
# These are STRUCTURAL tests — they validate that the benchmark script exits 0
# and produces JSON with the expected p95_ms/stage fields. They are NOT performance
# assertions. Iteration count is intentionally kept at 1 so the test completes
# well under the 120s CI per-test timeout enforced by suite-engine.sh —
# observed CI timeouts at iterations=2/3 caused unrelated PRs to fail
# (bug b129-ea9b, runs 25897171578 and 25898441281). Each iteration drives ~10
# python3 invocations across 5 stages; on a slow shared CI runner that compounds
# with python startup overhead well past the timeout.

set -uo pipefail

# Suppress dso ticket-show git fetch in CI (prevents _ensure_initialized hang).
# Same fix applied to test-implementation-plan-helpers.sh (commit d9ca99f3da).
export _TICKET_TEST_NO_SYNC=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BENCHMARK="$REPO_ROOT/plugins/dso/scripts/preconditions-benchmark.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

test_benchmark_measures_p95_per_stage() {
    # RED: preconditions-benchmark.sh does not exist yet
    if [[ ! -f "$BENCHMARK" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: preconditions-benchmark.sh to exist at %s\n  actual:   file not found\n" \
            "benchmark_measures_p95_per_stage" "$BENCHMARK" >&2
        return
    fi

    local output
    output=$(bash "$BENCHMARK" --iterations=1 --output=json 2>/dev/null)
    local exit_code=$?
    assert_eq "benchmark exits 0" "0" "$exit_code"

    # Should produce output with p95_ms per stage
    local has_p95
    has_p95=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
stages = data if isinstance(data, list) else [data]
has_p95 = all('p95_ms' in s for s in stages)
print('yes' if has_p95 else 'no')
" 2>/dev/null || echo "parse-error")
    assert_eq "benchmark output has p95_ms per stage" "yes" "$has_p95"
}

test_benchmark_outputs_p95_json() {
    # RED: preconditions-benchmark.sh does not exist yet
    if [[ ! -f "$BENCHMARK" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: preconditions-benchmark.sh to exist at %s\n  actual:   file not found\n" \
            "benchmark_outputs_p95_json" "$BENCHMARK" >&2
        return
    fi

    local output
    output=$(bash "$BENCHMARK" --iterations=1 --output=json 2>/dev/null)

    # Must be valid JSON
    local is_valid
    is_valid=$(echo "$output" | python3 -c "import json,sys; json.load(sys.stdin); print('valid')" 2>/dev/null || echo "invalid")
    assert_eq "benchmark output is valid JSON" "valid" "$is_valid"

    # Each entry must have stage and p95_ms
    local has_stage
    has_stage=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
stages = data if isinstance(data, list) else [data]
ok = all('stage' in s and 'p95_ms' in s for s in stages)
print('yes' if ok else 'no')
" 2>/dev/null || echo "parse-error")
    assert_eq "benchmark entries have stage and p95_ms" "yes" "$has_stage"
}

test_benchmark_measures_p95_per_stage
test_benchmark_outputs_p95_json

print_summary
