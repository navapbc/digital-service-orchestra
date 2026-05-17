#!/usr/bin/env bash
# tests/scripts/test-write-cycle-ledger-integration.sh
# Integration tests for plugins/dso/scripts/write-cycle-ledger.sh
#
# Verifies the full pipeline: shell → _flock_write_json / Python fcntl → JSON file on disk.
#
# Behaviors under test:
#   INT1. test_wcl_integration_full_pipeline   — full write and read: file exists, findings_hash correct, timestamp matches ISO-8601
#   INT2. test_wcl_integration_two_sequential  — two sequential writes accumulate correctly (2 entries, cycle_num==2 for second)
#   INT3. test_wcl_integration_concurrent_5    — 5 parallel writes produce valid JSON with 5 entries, no duplicate cycle_num
#
# Usage: bash tests/scripts/test-write-cycle-ledger-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/write-cycle-ledger.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Global cleanup registry — each test appends its temp dir here.
declare -a CLEANUP_DIRS=()
trap 'rm -rf "${CLEANUP_DIRS[@]:-}"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

_make_artifacts_dir() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-wcl-int-XXXXXX")
    CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ── INT1: Full pipeline write and read ───────────────────────────────────────

test_wcl_integration_full_pipeline() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$SCRIPT" \
        --epic-id=int-001 \
        --cycle-num=1 \
        --findings-hash=deadbeef 2>/dev/null || exit_code=$?

    assert_eq "INT1: write exits 0" "0" "$exit_code"

    local ledger_file="$artifacts_dir/cycle-ledger.json"

    if [[ -f "$ledger_file" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: INT1: cycle-ledger.json not created\n" >&2
        return
    fi

    local findings_hash
    findings_hash=$(python3 -c "
import json
d = json.load(open('$ledger_file'))
print(d['cycles'][0].get('findings_hash', 'missing'))
" 2>/dev/null || echo "parse-error")
    assert_eq "INT1: cycles[0].findings_hash equals deadbeef" "deadbeef" "$findings_hash"

    local timestamp_valid
    timestamp_valid=$(python3 -c "
import json, re
d = json.load(open('$ledger_file'))
ts = d['cycles'][0].get('timestamp_utc', '')
pattern = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
print('valid' if re.match(pattern, ts) else 'invalid:' + ts)
" 2>/dev/null || echo "parse-error")
    assert_eq "INT1: timestamp_utc matches ISO-8601 format" "valid" "$timestamp_valid"
}

test_wcl_integration_full_pipeline

# ── INT2: Two sequential writes accumulate correctly ─────────────────────────

test_wcl_integration_two_sequential() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # First write
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$SCRIPT" \
        --epic-id=int-seq \
        --cycle-num=1 \
        --findings-hash=hash-one 2>/dev/null || true

    # Second write
    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$SCRIPT" \
        --epic-id=int-seq \
        --cycle-num=2 \
        --findings-hash=hash-two 2>/dev/null || exit_code=$?

    assert_eq "INT2: second write exits 0" "0" "$exit_code"

    local ledger_file="$artifacts_dir/cycle-ledger.json"

    if [[ ! -f "$ledger_file" ]]; then
        (( ++FAIL ))
        printf "FAIL: INT2: cycle-ledger.json not created after two writes\n" >&2
        return
    fi

    local cycle_count
    cycle_count=$(python3 -c "
import json
d = json.load(open('$ledger_file'))
print(len(d.get('cycles', [])))
" 2>/dev/null || echo "0")
    assert_eq "INT2: cycles has 2 entries after two sequential writes" "2" "$cycle_count"

    local second_cycle_num
    second_cycle_num=$(python3 -c "
import json
d = json.load(open('$ledger_file'))
cycles = d.get('cycles', [])
print(cycles[1].get('cycle_num', 'missing') if len(cycles) > 1 else 'missing')
" 2>/dev/null || echo "parse-error")
    assert_eq "INT2: cycles[1].cycle_num == 2" "2" "$second_cycle_num"
}

test_wcl_integration_two_sequential

# ── INT3: Concurrent write integrity (5 parallel writes) ─────────────────────

test_wcl_integration_concurrent_5() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # Launch 5 parallel writes with distinct cycle numbers
    local pids=()
    local i
    for i in 1 2 3 4 5; do
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
            bash "$SCRIPT" \
            --epic-id=int-concurrent \
            --cycle-num="$i" \
            --findings-hash="hash-$i" 2>/dev/null &
        pids+=($!)
    done

    # Wait for all background processes
    local all_ok=0
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || all_ok=$((all_ok + 1))
    done

    local ledger_file="$artifacts_dir/cycle-ledger.json"

    if [[ ! -f "$ledger_file" ]]; then
        (( ++FAIL ))
        printf "FAIL: INT3: cycle-ledger.json not created after 5 concurrent writes\n" >&2
        return
    fi

    # Verify file is valid JSON
    local json_valid
    json_valid=$(python3 -c "
import json
try:
    data = json.load(open('$ledger_file'))
    print('valid')
except Exception as e:
    print('invalid:' + str(e))
" 2>/dev/null || echo "invalid:python-error")
    assert_eq "INT3: cycle-ledger.json is valid JSON after 5 concurrent writes" "valid" "$json_valid"

    # Verify all 5 entries are present
    local cycle_count
    cycle_count=$(python3 -c "
import json
d = json.load(open('$ledger_file'))
print(len(d.get('cycles', [])))
" 2>/dev/null || echo "0")
    assert_eq "INT3: cycles array length is 5 after 5 concurrent writes" "5" "$cycle_count"

    # Verify no duplicate cycle_num values
    local dup_count
    dup_count=$(python3 -c "
import json
d = json.load(open('$ledger_file'))
nums = [c.get('cycle_num') for c in d.get('cycles', [])]
print(len(nums) - len(set(nums)))
" 2>/dev/null || echo "error")
    assert_eq "INT3: no duplicate cycle_num values in concurrent write result" "0" "$dup_count"
}

test_wcl_integration_concurrent_5

print_summary
