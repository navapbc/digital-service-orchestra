#!/usr/bin/env bash
# plugins/dso/scripts/ticket-benchmark.sh
# Benchmark the ticket list command against a seeded ticket system.
#
# Usage: ticket-benchmark.sh [-n <count>] [--threshold <seconds>]
#   -n <count>         Number of tickets to seed (default: 300; 0 = use existing repo tickets)
#   --threshold <secs> Max acceptable wall-clock time in seconds
#                      Defaults: 3s for n<=300, 10s for n<=1000, 30s for n>1000
#
# When run without -n (or with -n 0) inside a repo that already has a ticket
# system initialized, benchmarks the existing tickets.  Otherwise creates a
# temporary git repo, seeds N tickets, and benchmarks that.
#
# Output: "Elapsed: X.XXs for N tickets" to stdout.
# Exit 0 if elapsed < threshold, exit 1 if elapsed >= threshold.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST_SCRIPT="$SCRIPT_DIR/ticket-list.sh"
REDUCER="$SCRIPT_DIR/ticket-reducer.py"

# ── Parse arguments ──────────────────────────────────────────────────────────
seed_count=0
threshold=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n)
            seed_count="${2:?'-n requires a count argument'}"
            shift 2
            ;;
        --threshold)
            threshold="${2:?'--threshold requires a seconds argument'}"
            shift 2
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            echo "Usage: ticket-benchmark.sh [-n <count>] [--threshold <seconds>]" >&2
            exit 2
            ;;
    esac
done

# ── Determine working mode ──────────────────────────────────────────────────
_tmp_dir=""
_cleanup() {
    if [[ -n "$_tmp_dir" ]] && [[ -d "$_tmp_dir" ]]; then
        rm -rf "$_tmp_dir"
    fi
}
trap _cleanup EXIT

tracker_dir=""

if [[ "$seed_count" -gt 0 ]]; then
    # Create a temporary git repo and seed tickets
    _tmp_dir=$(mktemp -d)
    local_repo="$_tmp_dir/repo"

    git init -q -b main "$local_repo"
    git -C "$local_repo" config user.email "benchmark@test.com"
    git -C "$local_repo" config user.name "Benchmark"
    echo "init" > "$local_repo/README.md"
    git -C "$local_repo" add -A
    git -C "$local_repo" commit -q -m "init"

    # Create tracker directory (mimics ticket init without the worktree machinery)
    tracker_dir="$local_repo/.tickets-tracker"
    mkdir -p "$tracker_dir"

    # Seed N tickets with CREATE events
    for (( i = 1; i <= seed_count; i++ )); do
        ticket_id=$(python3 -c "import uuid; u=str(uuid.uuid4()); print(u[:4]+'-'+u[4:8])")
        ts=$(python3 -c "import time; print(int(time.time() * 1_000_000_000))")
        event_uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")

        ticket_dir="$tracker_dir/$ticket_id"
        mkdir -p "$ticket_dir"

        python3 -c "
import json, sys
event = {
    'timestamp': int(sys.argv[1]),
    'uuid': sys.argv[2],
    'event_type': 'CREATE',
    'env_id': 'benchmark',
    'author': 'benchmark',
    'data': {
        'ticket_type': 'task',
        'title': 'Benchmark ticket ' + sys.argv[3]
    }
}
with open(sys.argv[4], 'w') as f:
    json.dump(event, f)
" "$ts" "$event_uuid" "$i" "$ticket_dir/${ts}-${event_uuid}-CREATE.json"
    done
else
    # Use the current repo's ticket system
    if [[ -n "${TICKETS_TRACKER_DIR:-}" ]]; then
        tracker_dir="$TICKETS_TRACKER_DIR"
    else
        repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
            echo "Error: not inside a git repository and -n not specified" >&2
            exit 1
        }
        tracker_dir="$repo_root/.tickets-tracker"
    fi

    if [[ ! -d "$tracker_dir" ]]; then
        echo "Error: ticket system not initialized at $tracker_dir" >&2
        exit 1
    fi

    # Count existing tickets
    seed_count=$(find "$tracker_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
fi

# ── Apply default threshold ──────────────────────────────────────────────────
if [[ -z "$threshold" ]]; then
    if [[ "$seed_count" -le 300 ]]; then
        threshold="3"
    elif [[ "$seed_count" -le 1000 ]]; then
        threshold="10"
    else
        threshold="30"
    fi
fi

# ── Measure ticket list wall-clock time ──────────────────────────────────────
start_time=$(python3 -c "import time; print(f'{time.time():.6f}')")

TICKETS_TRACKER_DIR="$tracker_dir" bash "$LIST_SCRIPT" >/dev/null 2>/dev/null

end_time=$(python3 -c "import time; print(f'{time.time():.6f}')")

# ── Compute elapsed and report ───────────────────────────────────────────────
elapsed=$(python3 -c "print(f'{float(\"$end_time\") - float(\"$start_time\"):.2f}')")

echo "Elapsed: ${elapsed}s for $seed_count tickets"

# ── Threshold check ──────────────────────────────────────────────────────────
over=$(python3 -c "print('1' if float('$elapsed') >= float('$threshold') else '0')")

if [[ "$over" == "1" ]]; then
    echo "FAIL: ${elapsed}s >= threshold ${threshold}s" >&2
    exit 1
fi

exit 0
