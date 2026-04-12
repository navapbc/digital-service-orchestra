#!/usr/bin/env bash
# emit-commit-workflow-event.sh
# Wrapper around emit-review-event.sh for commit workflow start/end events.
#
# Usage:
#   emit-commit-workflow-event.sh --phase=start
#   emit-commit-workflow-event.sh --phase=end --success=true|false [--failure-reason="..."]
#
# Environment variables:
#   WORKFLOW_PLUGIN_ARTIFACTS_DIR — directory for storing start timestamp artifact
#
# Best-effort: always returns 0, even if the underlying emit fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Add SCRIPT_DIR to PATH so emit-review-event.sh is discoverable,
# but allow callers to override via PATH (e.g., for testing stubs).
export PATH="$PATH:$SCRIPT_DIR"

# ── Parse arguments ──────────────────────────────────────────────────────────
phase=""
success=""
failure_reason=""

for arg in "$@"; do
    case "$arg" in
        --phase=*)   phase="${arg#--phase=}" ;;
        --success=*) success="${arg#--success=}" ;;
        --failure-reason=*) failure_reason="${arg#--failure-reason=}" ;;
    esac
done

if [ -z "$phase" ]; then
    echo "Error: --phase=start|end is required" >&2
    exit 0  # best-effort
fi

# ── Resolve artifacts directory ──────────────────────────────────────────────
artifacts_dir="${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-}"
if [ -z "$artifacts_dir" ]; then
    echo "Warning: WORKFLOW_PLUGIN_ARTIFACTS_DIR not set" >&2
    exit 0  # best-effort
fi
mkdir -p "$artifacts_dir" 2>/dev/null || true

ts_file="$artifacts_dir/commit-workflow-start-ts"

# ── Phase: start ─────────────────────────────────────────────────────────────
if [ "$phase" = "start" ]; then
    # Record wall-clock timestamp (epoch milliseconds)
    start_ms=$(python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null) || start_ms=""
    if [ -z "$start_ms" ]; then
        exit 0  # best-effort
    fi

    # Persist to artifact file for duration calculation
    printf '%s' "$start_ms" > "$ts_file" 2>/dev/null || true

    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || timestamp=""

    # Build JSON payload
    json=$(python3 -c "
import json, sys
print(json.dumps({
    'event_type': 'commit_workflow',
    'phase': 'start',
    'timestamp': sys.argv[1]
}, separators=(',', ':')))
" "$timestamp" 2>/dev/null) || json=""

    if [ -n "$json" ]; then
        # Emit event — stdout for callers, emit-review-event.sh for persistence
        echo "$json"
        bash emit-review-event.sh "$json" 2>/dev/null || true
    fi

    exit 0
fi

# ── Phase: end ───────────────────────────────────────────────────────────────
if [ "$phase" = "end" ]; then
    # Read start timestamp for duration calculation
    duration_ms=0
    if [ -f "$ts_file" ]; then
        start_ms=$(cat "$ts_file" 2>/dev/null) || start_ms=""
        if [ -n "$start_ms" ]; then
            now_ms=$(python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null) || now_ms=""
            if [ -n "$now_ms" ]; then
                duration_ms=$(( now_ms - start_ms ))
            fi
        fi
    fi

    # Determine success boolean
    success_bool="false"
    if [ "$success" = "true" ]; then
        success_bool="true"
    fi

    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || timestamp=""

    # Build JSON payload
    json=$(python3 -c "
import json, sys

data = {
    'event_type': 'commit_workflow',
    'phase': 'end',
    'timestamp': sys.argv[1],
    'success': sys.argv[2] == 'true',
    'duration_ms': int(sys.argv[3])
}

failure_reason = sys.argv[4] if len(sys.argv) > 4 else ''
if failure_reason:
    data['failure_reason'] = failure_reason

print(json.dumps(data, separators=(',', ':')))
" "$timestamp" "$success_bool" "$duration_ms" "$failure_reason" 2>/dev/null) || json=""

    if [ -n "$json" ]; then
        echo "$json"
        bash emit-review-event.sh "$json" 2>/dev/null || true
    fi

    exit 0
fi

# Unknown phase — best-effort, just exit 0
exit 0
