#!/usr/bin/env bash
# tests/perf/ticket-list-timing.sh
# Performance regression guard for ticket-list (exclude_archived=true) with
# the fast-skip optimization.
#
# What this tests:
#   Provisions a TICKETS_TRACKER_DIR with 500 synthetic tickets
#   (400 with .archived marker, 100 without), times 'ticket list'
#   (exclude_archived=true) 3 times, and asserts the median is below
#   the --threshold (default: 2 seconds wall-clock).
#
# This is a RED test: it will fail before the fast-skip optimization is
# implemented in reduce_all_tickets(), and pass after.
#
# Usage:
#   bash tests/perf/ticket-list-timing.sh [--threshold=<seconds>]
#
# Exit: 0 = PASS, non-zero = FAIL

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TICKET_LIST_SH="$REPO_ROOT/plugins/dso/scripts/ticket-list.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────
threshold_secs=2
for arg in "$@"; do
    case "$arg" in
        --threshold=*)
            threshold_secs="${arg#--threshold=}"
            ;;
        --help|-h)
            echo "Usage: $0 [--threshold=<seconds>]"
            echo "  --threshold=N  Wall-clock median threshold in seconds (default: 2)"
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$arg'" >&2
            exit 1
            ;;
    esac
done

# ── Validate dependencies ─────────────────────────────────────────────────────
if [ ! -x "$TICKET_LIST_SH" ]; then
    echo "FAIL: ticket-list.sh not found or not executable: $TICKET_LIST_SH" >&2
    exit 1
fi

# ── Provision synthetic tracker ───────────────────────────────────────────────
TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT

echo "Provisioning 500 synthetic tickets (400 archived, 100 active)..."

python3 - "$TDIR" <<'PYEOF'
import json
import os
import sys

tracker_dir = sys.argv[1]
base_ts = 1_000_000_000

for i in range(500):
    ticket_id = f"perf-ticket-{i:04d}"
    ticket_dir = os.path.join(tracker_dir, ticket_id)
    os.makedirs(ticket_dir, exist_ok=True)

    # CREATE event
    create_event = {
        "timestamp": base_ts + i,
        "uuid": f"create-{i:04d}-aaaa-bbbb-cccc-ddddeeee{i:04d}",
        "event_type": "CREATE",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "author": "perf-test",
        "data": {
            "ticket_type": "task",
            "title": f"Synthetic perf ticket {i}",
            "priority": 3,
        },
    }
    create_file = os.path.join(
        ticket_dir,
        f"{base_ts + i}-create-{i:04d}-CREATE.json",
    )
    with open(create_file, "w") as f:
        json.dump(create_event, f)

    if i < 400:
        # Archived: write STATUS closed + ARCHIVED event + .archived marker
        status_ts = base_ts + i + 1
        status_event = {
            "timestamp": status_ts,
            "uuid": f"status-{i:04d}-aaaa-bbbb-cccc-ddddeeee{i:04d}",
            "event_type": "STATUS",
            "env_id": "00000000-0000-4000-8000-000000000001",
            "author": "perf-test",
            "data": {"status": "closed"},
        }
        status_file = os.path.join(
            ticket_dir,
            f"{status_ts}-status-{i:04d}-STATUS.json",
        )
        with open(status_file, "w") as f:
            json.dump(status_event, f)

        archived_ts = base_ts + i + 2
        archived_event = {
            "timestamp": archived_ts,
            "uuid": f"arch-{i:04d}-aaaa-bbbb-cccc-ddddeeee{i:04d}",
            "event_type": "ARCHIVED",
            "env_id": "00000000-0000-4000-8000-000000000001",
            "author": "perf-test",
            "data": {},
        }
        archived_file = os.path.join(
            ticket_dir,
            f"{archived_ts}-arch-{i:04d}-ARCHIVED.json",
        )
        with open(archived_file, "w") as f:
            json.dump(archived_event, f)

        # Drop the .archived marker file (fast-skip optimization reads this)
        marker_file = os.path.join(ticket_dir, ".archived")
        open(marker_file, "w").close()

print(f"Done: created 500 ticket dirs in {tracker_dir}")
PYEOF

echo "Provisioning complete."

# ── Time 'ticket list' 3 runs ─────────────────────────────────────────────────
echo "Timing 'ticket list' (exclude_archived=true) — 3 runs..."

# time_run: run ticket-list.sh (no --include-archived ↔ exclude_archived=true)
# and return elapsed seconds.  Uses bash built-in SECONDS for integer precision
# when python3 high-res timing is unavailable.
time_run() {
    local start end elapsed
    start=$(python3 -c "import time; print(time.monotonic())")
    TICKETS_TRACKER_DIR="$TDIR" bash "$TICKET_LIST_SH" > /dev/null 2>&1
    end=$(python3 -c "import time; print(time.monotonic())")
    python3 -c "print(f'{$end - $start:.3f}')"
}

t1=$(time_run)
t2=$(time_run)
t3=$(time_run)

echo "  Run 1: ${t1}s"
echo "  Run 2: ${t2}s"
echo "  Run 3: ${t3}s"

# ── Compute median ────────────────────────────────────────────────────────────
median=$(python3 - "$t1" "$t2" "$t3" <<'PYEOF'
import sys
vals = sorted(float(v) for v in sys.argv[1:])
# median of 3: middle value
print(f"{vals[1]:.3f}")
PYEOF
)

echo "  Median: ${median}s  (threshold: ${threshold_secs}s)"

# ── Assert ────────────────────────────────────────────────────────────────────
result=$(python3 -c "
import sys
median = float('$median')
threshold = float('$threshold_secs')
print('PASS' if median < threshold else 'FAIL')
")

if [ "$result" = "PASS" ]; then
    echo "PASS: median ${median}s < ${threshold_secs}s threshold"
    exit 0
else
    echo "FAIL: median ${median}s >= ${threshold_secs}s threshold (fast-skip optimization may not be active)"
    exit 1
fi
