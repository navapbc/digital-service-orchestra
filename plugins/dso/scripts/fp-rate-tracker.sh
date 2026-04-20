#!/usr/bin/env bash
# fp-rate-tracker.sh
# Tracks false-positive (FP) rate for PRECONDITIONS events on a ticket.
# When the rate exceeds the threshold, engages fallback (emits FALLBACK_ENGAGED signal).
#
# Usage:
#   fp-rate-tracker.sh --ticket-id=<id> [--threshold=<float>]
#
# Flags:
#   --ticket-id=<id>      The ticket to analyze (required)
#   --threshold=<float>   FP rate threshold for fallback (default: 0.10)
#
# Behavior:
#   - Reads PRECONDITIONS events for the ticket from TICKETS_TRACKER_DIR
#   - Counts events where data.fp_flagged=true
#   - Computes rate = fp_flagged_count / total_event_count
#   - When rate > threshold: emits FALLBACK_ENGAGED signal to stdout
#     and writes a new minimal-tier PRECONDITIONS event with data.fallback_engaged=true
#   - Always exits 0 (fallback is advisory, non-blocking)
#
# Scope contract (fp-auto-fallback-scope.md):
#   - Per-write: only new events affected, never retroactive
#   - Per-ticket: not global, not per-epic
#   - Validators stay depth-agnostic regardless of fallback state

set -uo pipefail

_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

# ── Argument parsing ─────────────────────────────────────────────────────────
_TICKET_ID=""
_THRESHOLD="0.10"

for _arg in "$@"; do
    case "$_arg" in
        --ticket-id=*)
            _TICKET_ID="${_arg#--ticket-id=}"
            ;;
        --threshold=*)
            _THRESHOLD="${_arg#--threshold=}"
            ;;
        *)
            echo "ERROR: unknown argument: $_arg" >&2
            echo "Usage: fp-rate-tracker.sh --ticket-id=<id> [--threshold=<float>]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$_TICKET_ID" ]]; then
    echo "ERROR: --ticket-id is required" >&2
    exit 1
fi

# ── Resolve ticket directory ──────────────────────────────────────────────────
# Support TICKETS_TRACKER_DIR override for tests; else find .tickets-tracker
if [[ -n "${TICKETS_TRACKER_DIR:-}" ]]; then
    _TRACKER_DIR="$TICKETS_TRACKER_DIR"
else
    # Walk up from cwd to find .tickets-tracker
    _REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
    _TRACKER_DIR="$_REPO_ROOT/.tickets-tracker"
fi

_TICKET_DIR="$_TRACKER_DIR/$_TICKET_ID"

if [[ ! -d "$_TICKET_DIR" ]]; then
    # No events for this ticket — nothing to track
    exit 0
fi

# ── Read and analyze PRECONDITIONS events ────────────────────────────────────
python3 - <<PYEOF
import json, os, sys, glob

ticket_dir = "$_TICKET_DIR"
threshold = float("$_THRESHOLD")
ticket_id = "$_TICKET_ID"

# Find all PRECONDITIONS event files
event_files = sorted(glob.glob(os.path.join(ticket_dir, "*-PRECONDITIONS.json")))

total = 0
fp_count = 0
for path in event_files:
    try:
        with open(path) as f:
            event = json.load(f)
        total += 1
        data = event.get("data", {})
        if data.get("fp_flagged") is True:
            fp_count += 1
    except Exception:
        pass  # Skip malformed events

if total == 0:
    sys.exit(0)

fp_rate = fp_count / total

if fp_rate > threshold:
    # Emit FALLBACK_ENGAGED signal to stdout
    signal = {
        "signal": "FALLBACK_ENGAGED",
        "ticket_id": ticket_id,
        "fp_rate": round(fp_rate, 4),
        "threshold": threshold,
    }
    print(json.dumps(signal))

    # Write a new minimal-tier PRECONDITIONS event with fallback_engaged=true
    import time, uuid as _uuid
    ts = int(time.time() * 1000)
    uid = _uuid.uuid4().hex[:8]
    fallback_event = {
        "event_type": "PRECONDITIONS",
        "gate_name": "fp-rate-tracker",
        "session_id": os.environ.get("SESSION_ID", "fp-tracker-session"),
        "worktree_id": os.environ.get("WORKTREE_ID", ""),
        "tier": "minimal",
        "timestamp": ts,
        "data": {
            "fallback_engaged": True,
            "fp_rate": round(fp_rate, 4),
            "threshold": threshold,
        },
        "schema_version": "2",
        "manifest_depth": "minimal",
    }
    event_path = os.path.join(ticket_dir, f"{ts}000-{uid}-PRECONDITIONS.json")
    with open(event_path, "w") as f:
        json.dump(fallback_event, f)

sys.exit(0)
PYEOF
