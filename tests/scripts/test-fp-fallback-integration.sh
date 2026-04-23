#!/usr/bin/env bash
# tests/scripts/test-fp-fallback-integration.sh
# Integration tests for FP auto-fallback mid-workflow behavior.
# Tests that fallback engages correctly and existing events remain valid.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FP_TRACKER="$REPO_ROOT/plugins/dso/scripts/fp-rate-tracker.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

_make_tracker_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local tracker_dir="$tmpdir/.tickets-tracker"
    mkdir -p "$tracker_dir"
    echo "$tmpdir"
}

_write_preconditions_event() {
    local ticket_dir="$1"
    local ts="$2"
    local uid="$3"
    local tier="$4"
    local fp_flagged="${5:-false}"
    cat > "$ticket_dir/${ts}-${uid}-PRECONDITIONS.json" <<EOF
{"event_type":"PRECONDITIONS","gate_name":"test-gate","session_id":"sess1","worktree_id":"wt1","tier":"${tier}","timestamp":${ts},"data":{"fp_flagged":${fp_flagged}},"schema_version":"2","manifest_depth":"${tier}"}
EOF
}

test_fp_fallback_mid_workflow() {
    local tmpdir
    tmpdir=$(_make_tracker_env)
    local tracker_dir="$tmpdir/.tickets-tracker"
    local ticket_id
    ticket_id="ticket-$(date +%s)"
    local ticket_dir="$tracker_dir/$ticket_id"
    mkdir -p "$ticket_dir"

    # Write 7 total events: 5 non-FP (standard tier), 2 FP-flagged
    # Rate = 2/7 ≈ 28.6%, well above 10% threshold
    local ts=1700000001000
    for i in $(seq 1 5); do
        _write_preconditions_event "$ticket_dir" "$ts" "uuid${i}" "standard" "false"
        ts=$((ts + 1000))
    done
    for i in $(seq 6 7); do
        _write_preconditions_event "$ticket_dir" "$ts" "uuid${i}" "standard" "true"
        ts=$((ts + 1000))
    done

    local before_count
    before_count=$(find "$ticket_dir" -name "*-PRECONDITIONS.json" | wc -l | tr -d ' ')
    assert_eq "7 events written before fallback" "7" "$before_count"

    # Invoke fp-rate-tracker
    local output
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" bash "$FP_TRACKER" --ticket-id="$ticket_id" --threshold=0.10 2>&1)
    local exit_code=$?

    # Must exit 0 (advisory)
    assert_eq "fp-rate-tracker exits 0" "0" "$exit_code"

    # Output must contain FALLBACK_ENGAGED signal
    local has_signal
    has_signal=$(echo "$output" | grep -c "FALLBACK_ENGAGED" || echo 0)
    assert_ne "FALLBACK_ENGAGED signal emitted" "0" "$has_signal"

    # A new minimal-tier event must have been written
    local after_count
    after_count=$(find "$ticket_dir" -name "*-PRECONDITIONS.json" | wc -l | tr -d ' ')
    assert_eq "one new minimal-tier event written after fallback" "8" "$after_count"

    rm -rf "$tmpdir"
}

test_fallback_new_events_are_minimal() {
    local tmpdir
    tmpdir=$(_make_tracker_env)
    local tracker_dir="$tmpdir/.tickets-tracker"
    local ticket_id
    ticket_id="ticket2-$(date +%s)"
    local ticket_dir="$tracker_dir/$ticket_id"
    mkdir -p "$ticket_dir"

    # Write 5 events with 2 FP-flagged (40% rate)
    local ts=1700100001000
    for i in $(seq 1 3); do
        _write_preconditions_event "$ticket_dir" "$ts" "u${i}" "standard" "false"
        ts=$((ts + 1000))
    done
    for i in $(seq 4 5); do
        _write_preconditions_event "$ticket_dir" "$ts" "u${i}" "standard" "true"
        ts=$((ts + 1000))
    done

    TICKETS_TRACKER_DIR="$tracker_dir" bash "$FP_TRACKER" --ticket-id="$ticket_id" --threshold=0.10 2>/dev/null

    # The newest event (written by fallback) must be minimal tier with fallback_engaged=true
    local newest_event
    newest_event=$(find "$ticket_dir" -name "*-PRECONDITIONS.json" | sort | tail -1)
    assert_ne "a new fallback event exists" "" "$newest_event"

    local is_minimal
    is_minimal=$(python3 -c "
import json
with open('$newest_event') as f:
    event = json.load(f)
tier = event.get('tier', '')
fallback = event.get('data', {}).get('fallback_engaged', False)
print('yes' if tier == 'minimal' and fallback is True else f'no: tier={tier} fallback_engaged={fallback}')
" 2>/dev/null || echo "parse-error")
    assert_eq "fallback event is minimal tier with fallback_engaged=true" "yes" "$is_minimal"

    # Original standard-tier events must remain valid JSON
    local invalid_count=0
    while IFS= read -r -d '' event_file; do
        python3 -c "import json; json.load(open('$event_file'))" 2>/dev/null || (( ++invalid_count ))
    done < <(find "$ticket_dir" -name "*-PRECONDITIONS.json" -print0)

    assert_eq "all events (original + fallback) remain valid JSON" "0" "$invalid_count"

    rm -rf "$tmpdir"
}

test_fp_fallback_mid_workflow
test_fallback_new_events_are_minimal

print_summary
