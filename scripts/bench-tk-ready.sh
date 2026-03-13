#!/usr/bin/env bash
# lockpick-workflow/scripts/bench-tk-ready.sh
# Measures wall-clock time of `tk ready` and exits non-zero if it exceeds the threshold.
#
# Usage:
#   bash lockpick-workflow/scripts/bench-tk-ready.sh
#   BENCH_THRESHOLD_SECONDS=5 bash lockpick-workflow/scripts/bench-tk-ready.sh
#
# Timing method: uses $SECONDS bash builtin (integer second resolution).
#   This is sufficient for a 3-second performance gate. Sub-second precision
#   is intentionally omitted — the $SECONDS builtin avoids platform differences
#   between GNU date (+%N nanoseconds) and macOS date (no nanosecond support).
#
# Exit codes:
#   0 — tk ready completed within threshold
#   1 — tk ready exceeded threshold (or tk not found)
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TK="${TK:-$SCRIPT_DIR/tk}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Default threshold: 3 seconds. Override via BENCH_THRESHOLD_SECONDS env var.
THRESHOLD="${BENCH_THRESHOLD_SECONDS:-3}"

# ---------------------------------------------------------------------------
# Verify tk is available
# ---------------------------------------------------------------------------
if [ ! -x "$TK" ]; then
    echo "ERROR: 'tk' not found at $TK" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Time the tk ready invocation
# ---------------------------------------------------------------------------
# $SECONDS is a bash builtin that contains the number of seconds since the
# shell was started. Capture start/end to compute elapsed integer seconds.
start_seconds=$SECONDS
"$TK" ready > /dev/null 2>&1
end_seconds=$SECONDS
elapsed=$(( end_seconds - start_seconds ))

# ---------------------------------------------------------------------------
# Report and evaluate
# ---------------------------------------------------------------------------
printf "tk ready retrieval time: %ds\n" "$elapsed"

if [ "$elapsed" -ge "$THRESHOLD" ]; then
    printf "WARNING: tk ready exceeded %ss threshold (%ss)\n" "$THRESHOLD" "$elapsed" >&2
    exit 1
fi

exit 0
