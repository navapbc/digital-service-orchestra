#!/usr/bin/env bash
# tests/scripts/test-fp-rate-tracker.sh
# RED tests for plugins/dso/scripts/fp-rate-tracker.sh
# These tests fail RED until fp-rate-tracker.sh is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FP_TRACKER="$REPO_ROOT/plugins/dso/scripts/fp-rate-tracker.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

test_fp_rate_tracker_engages_fallback() {
    # RED: fp-rate-tracker.sh does not exist yet
    if [[ ! -f "$FP_TRACKER" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: fp-rate-tracker.sh to exist at %s\n  actual:   file not found\n" \
            "fp_rate_tracker_engages_fallback" "$FP_TRACKER" >&2
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local tracker_dir="$tmpdir/.tickets-tracker"
    local ticket_id
    ticket_id="test-$(date +%s)"
    local ticket_dir="$tracker_dir/$ticket_id"
    mkdir -p "$ticket_dir"

    # Write 10 total events: 4 with fp_flagged=true (40% rate > 10% threshold)
    local ts=1700000000000
    for i in $(seq 1 6); do
        cat > "$ticket_dir/${ts}000-uuid${i}-PRECONDITIONS.json" <<EOF
{"event_type":"PRECONDITIONS","gate_name":"test-gate","session_id":"sess1","worktree_id":"wt1","tier":"standard","timestamp":${ts},"data":{"fp_flagged":false},"schema_version":"2","manifest_depth":"standard"}
EOF
        ts=$((ts + 1000))
    done
    for i in $(seq 7 10); do
        cat > "$ticket_dir/${ts}000-uuid${i}-PRECONDITIONS.json" <<EOF
{"event_type":"PRECONDITIONS","gate_name":"test-gate","session_id":"sess1","worktree_id":"wt1","tier":"standard","timestamp":${ts},"data":{"fp_flagged":true},"schema_version":"2","manifest_depth":"standard"}
EOF
        ts=$((ts + 1000))
    done

    local output
    output=$(TICKETS_TRACKER_DIR="$tracker_dir" bash "$FP_TRACKER" --ticket-id="$ticket_id" --threshold=0.10 2>&1)
    local exit_code=$?

    # Script must exit 0 (fallback is advisory)
    assert_eq "fp-rate-tracker exits 0" "0" "$exit_code"

    # Output must contain FALLBACK_ENGAGED signal
    local has_signal
    has_signal=$(echo "$output" | grep -c "FALLBACK_ENGAGED" || echo 0)
    assert_ne "FALLBACK_ENGAGED signal emitted when rate > threshold" "0" "$has_signal"

    rm -rf "$tmpdir"
}

test_fallback_does_not_truncate_existing_events() {
    # RED: fp-rate-tracker.sh does not exist yet
    if [[ ! -f "$FP_TRACKER" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: fp-rate-tracker.sh to exist at %s\n  actual:   file not found\n" \
            "fallback_does_not_truncate_existing_events" "$FP_TRACKER" >&2
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local tracker_dir="$tmpdir/.tickets-tracker"
    local ticket_id
    ticket_id="test-$(date +%s)-b"
    local ticket_dir="$tracker_dir/$ticket_id"
    mkdir -p "$ticket_dir"

    # Write 2 standard-tier events (content we will verify remains intact)
    local ts=1700001000000
    echo '{"event_type":"PRECONDITIONS","gate_name":"gate-A","session_id":"sess1","worktree_id":"wt1","tier":"standard","timestamp":1700001000000,"data":{"fp_flagged":false},"schema_version":"2","manifest_depth":"standard"}' \
        > "$ticket_dir/${ts}000-uuidA-PRECONDITIONS.json"
    ts=$((ts + 1000))
    echo '{"event_type":"PRECONDITIONS","gate_name":"gate-B","session_id":"sess1","worktree_id":"wt1","tier":"standard","timestamp":1700002000000,"data":{"fp_flagged":true},"schema_version":"2","manifest_depth":"standard"}' \
        > "$ticket_dir/${ts}000-uuidB-PRECONDITIONS.json"

    # Count events before fallback
    local before_count
    before_count=$(find "$ticket_dir" -name "*-PRECONDITIONS.json" | wc -l | tr -d ' ')

    TICKETS_TRACKER_DIR="$tracker_dir" bash "$FP_TRACKER" --ticket-id="$ticket_id" --threshold=0.10 2>/dev/null

    # Events that existed before fallback must still be valid JSON
    local invalid_count=0
    while IFS= read -r -d '' event_file; do
        python3 -c "import json; json.load(open('$event_file'))" 2>/dev/null || (( ++invalid_count ))
    done < <(find "$ticket_dir" -name "*-PRECONDITIONS.json" -print0)

    assert_eq "existing events remain valid JSON after fallback" "0" "$invalid_count"

    rm -rf "$tmpdir"
}

test_fp_rate_tracker_engages_fallback
test_fallback_does_not_truncate_existing_events

print_summary
