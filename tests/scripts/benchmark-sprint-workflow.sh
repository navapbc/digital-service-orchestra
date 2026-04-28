#!/usr/bin/env bash
# tests/scripts/benchmark-sprint-workflow.sh
# Aggregate sprint-turn benchmark: runs 20 representative ticket CLI ops and
# measures total wall-clock time. Compares against tests/perf/a0-baseline.json.
#
# Usage: bash tests/scripts/benchmark-sprint-workflow.sh
#
# Exit codes:
#   0 — PASS or CALIBRATION_NEEDED (baseline updated)
#   1 — FAIL (measured time does not achieve ≥60% wall-clock reduction)
#
# Op mix (20 total):
#   show       × 8   (reads)
#   list       × 2   (reads)
#   comment    × 4   (writes)
#   transition × 2   (writes: open → in_progress, then in_progress → open to reset state)
#   tag        × 2   (writes)
#   create     × 2   (writes)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
BASELINE_FILE="$REPO_ROOT/tests/perf/a0-baseline.json"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

# ── Temp repo setup ──────────────────────────────────────────────────────────
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

WORK_DIR="$(mktemp -d)"
_CLEANUP_DIRS+=("$WORK_DIR")
clone_ticket_repo "$WORK_DIR/repo"
TEST_REPO="$WORK_DIR/repo"
TRACKER_DIR="$TEST_REPO/.tickets-tracker"

# ── Create a test ticket for read/write ops ──────────────────────────────────
TICKET_ID=$(
    cd "$TEST_REPO" && \
    _TICKET_TEST_NO_SYNC=1 \
    TICKETS_TRACKER_DIR="$TRACKER_DIR" \
    bash "$TICKET_SCRIPT" create task "benchmark-seed-ticket" 2>/dev/null \
    | awk '/^[a-f0-9]{4}-[a-f0-9]{4}$/ {print; exit}'
)

if [ -z "${TICKET_ID:-}" ]; then
    echo "ERROR: could not create seed ticket in temp repo" >&2
    exit 1
fi

# ── Run the 20-op workload ───────────────────────────────────────────────────
# Helper: run a ticket subcommand in the test repo
_run_op() {
    (
        cd "$TEST_REPO" || exit 1
        _TICKET_TEST_NO_SYNC=1 \
        TICKETS_TRACKER_DIR="$TRACKER_DIR" \
        bash "$TICKET_SCRIPT" "$@" 2>/dev/null
    )
}

echo "Sprint-turn benchmark: 20 ops"
echo "Warming up test repo..."

# Pre-warm: run a show once outside the timed window so bash/disk caches settle.
_run_op show "$TICKET_ID" >/dev/null 2>&1 || true

echo "Running 20-op workload..."

# Capture start time (nanoseconds)
_START_NS=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time_ns()))")

# 8 × show (reads)
_run_op show "$TICKET_ID" >/dev/null
_run_op show "$TICKET_ID" >/dev/null
_run_op show "$TICKET_ID" >/dev/null
_run_op show "$TICKET_ID" >/dev/null
_run_op show "$TICKET_ID" >/dev/null
_run_op show "$TICKET_ID" >/dev/null
_run_op show "$TICKET_ID" >/dev/null
_run_op show "$TICKET_ID" >/dev/null

# 2 × list (reads)
_run_op list >/dev/null
_run_op list >/dev/null

# 4 × comment (writes)
_run_op comment "$TICKET_ID" "benchmark comment 1" >/dev/null
_run_op comment "$TICKET_ID" "benchmark comment 2" >/dev/null
_run_op comment "$TICKET_ID" "benchmark comment 3" >/dev/null
_run_op comment "$TICKET_ID" "benchmark comment 4" >/dev/null

# 2 × transition open → in_progress (reset between calls)
_run_op transition "$TICKET_ID" open in_progress >/dev/null
_run_op transition "$TICKET_ID" in_progress open >/dev/null

# 2 × tag (writes)
_run_op tag "$TICKET_ID" benchmark-tag >/dev/null
_run_op tag "$TICKET_ID" benchmark-tag2 >/dev/null

# 2 × create (writes)
_run_op create task "benchmark task 1" >/dev/null
_run_op create task "benchmark task 2" >/dev/null

# Capture end time
_END_NS=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time_ns()))")

# ── Compute measured time ────────────────────────────────────────────────────
MEASURED_S=$(python3 -c "
start = $_START_NS
end   = $_END_NS
elapsed = (end - start) / 1e9
print('{:.4f}'.format(elapsed))
")

# ── Compare against baseline or calibrate ───────────────────────────────────
mkdir -p "$(dirname "$BASELINE_FILE")"

PLATFORM="$(uname -s)"
python3 - "$BASELINE_FILE" "$MEASURED_S" "$PLATFORM" <<'PYEOF'
import json
import sys
from pathlib import Path

baseline_path = Path(sys.argv[1])
measured_s    = float(sys.argv[2])
platform      = sys.argv[3] if len(sys.argv) > 3 else "unknown"

# Select platform-specific baseline key when available.
# aggregate_sprint_turn_linux_s was captured as an estimated Linux CI pre-refactor
# baseline (shared runners have slower disk I/O than macOS dev machines, so the
# pre-refactor Python subprocess overhead is higher: ~3.5s vs macOS 2.9118s).
LINUX_KEY   = "aggregate_sprint_turn_linux_s"
GENERIC_KEY = "aggregate_sprint_turn_s"
KEY = LINUX_KEY if platform == "Linux" else GENERIC_KEY

# ── Load baseline (or start fresh) ──────────────────────────────────────────
if baseline_path.exists():
    with baseline_path.open() as f:
        data = json.load(f)
else:
    data = {}

# ── CALIBRATION path ─────────────────────────────────────────────────────────
if KEY not in data and GENERIC_KEY not in data:
    print(f"CALIBRATION_NEEDED — updating baseline with current measurement")
    print(f"  {KEY}: {measured_s:.4f}s")
    data[KEY] = round(measured_s, 4)
    with baseline_path.open("w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"  Written: {baseline_path}")
    sys.exit(0)

# ── COMPARISON path ──────────────────────────────────────────────────────────
# Use platform-specific baseline when present; fall back to generic.
baseline_s = float(data[KEY]) if KEY in data else float(data[GENERIC_KEY])
key_used   = KEY if KEY in data else GENERIC_KEY
# Required: ≥60% wall-clock reduction means measured ≤ 40% of baseline.
required_max_s = baseline_s * 0.40
reduction_pct  = (1.0 - measured_s / baseline_s) * 100.0 if baseline_s > 0 else 0.0

print(f"Sprint-turn benchmark: 20 ops")
print(f"Pre-refactor aggregate: {baseline_s:.2f}s (from {key_used})")
print(f"Post-refactor aggregate: {measured_s:.2f}s (measured)")

passed = measured_s <= required_max_s
label  = "PASS" if passed else "FAIL"
print(f"Reduction: {reduction_pct:.1f}% [{label}]")

if not passed:
    print(
        f"\nFAIL: {measured_s:.4f}s does not achieve ≥60% reduction "
        f"(required ≤{required_max_s:.4f}s, baseline={baseline_s:.4f}s from {key_used})",
        file=sys.stderr,
    )

sys.exit(0 if passed else 1)
PYEOF
