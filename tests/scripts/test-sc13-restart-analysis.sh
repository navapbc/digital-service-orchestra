#!/usr/bin/env bash
# tests/scripts/test-sc13-restart-analysis.sh
# RED tests for plugins/dso/scripts/sc13-restart-analysis.sh
# These tests fail RED until sc13-restart-analysis.sh is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SC13="$REPO_ROOT/plugins/dso/scripts/sc13-restart-analysis.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

test_sc13_analysis_computes_drop() {
    # RED: sc13-restart-analysis.sh does not exist yet
    if [[ ! -f "$SC13" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: sc13-restart-analysis.sh to exist at %s\n  actual:   file not found\n" \
            "sc13_analysis_computes_drop" "$SC13" >&2
        return
    fi

    local output
    output=$(bash "$SC13" --baseline-restart-rate=0.40 --post-restart-rate=0.20 --sample-size=100 2>/dev/null)
    local exit_code=$?
    assert_eq "sc13-restart-analysis exits 0" "0" "$exit_code"

    # drop_pct = (0.40 - 0.20) / 0.40 * 100 = 50.0
    local drop_pct
    drop_pct=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('drop_pct', 'missing'))
" 2>/dev/null || echo "parse-error")

    # Allow ±1 float tolerance
    local is_approx_50
    is_approx_50=$(python3 -c "
try:
    v = float('$drop_pct')
    print('yes' if abs(v - 50.0) < 1.0 else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")
    assert_eq "drop_pct computes correctly (50% expected)" "yes" "$is_approx_50"
}

test_sc13_outputs_methodology_json() {
    # RED: sc13-restart-analysis.sh does not exist yet
    if [[ ! -f "$SC13" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: sc13-restart-analysis.sh to exist at %s\n  actual:   file not found\n" \
            "sc13_outputs_methodology_json" "$SC13" >&2
        return
    fi

    local output
    output=$(bash "$SC13" --baseline-restart-rate=0.30 --post-restart-rate=0.15 --sample-size=200 2>/dev/null)

    # Must be valid JSON
    local is_valid
    is_valid=$(echo "$output" | python3 -c "import json,sys; json.load(sys.stdin); print('valid')" 2>/dev/null || echo "invalid")
    assert_eq "sc13 output is valid JSON" "valid" "$is_valid"

    # Must contain baseline_rate, post_rate, drop_pct
    local has_fields
    has_fields=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
required = ['baseline_rate', 'post_rate', 'drop_pct']
ok = all(k in data for k in required)
print('yes' if ok else 'no: missing ' + str([k for k in required if k not in data]))
" 2>/dev/null || echo "parse-error")
    assert_eq "sc13 output has baseline_rate, post_rate, drop_pct" "yes" "$has_fields"

    # Must contain methodology field
    local has_methodology
    has_methodology=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('yes' if 'methodology' in data else 'no')
" 2>/dev/null || echo "parse-error")
    assert_eq "sc13 output has methodology field" "yes" "$has_methodology"
}

test_sc13_analysis_computes_drop
test_sc13_outputs_methodology_json

print_summary
