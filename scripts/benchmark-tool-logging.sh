#!/usr/bin/env bash
set -uo pipefail
# scripts/benchmark-tool-logging.sh
# Benchmark tool-logging.sh overhead by running it N times with synthetic input.
#
# Usage: benchmark-tool-logging.sh [iterations]
#   iterations: number of runs (default: 10)
#
# Output: min/avg/max/p95 overhead in milliseconds for both pre and post modes.
# Works with tool-logging both enabled and disabled.

set -uo pipefail

ITERATIONS="${1:-10}"

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL_LOGGING_HOOK="$PLUGIN_ROOT/hooks/tool-logging.sh"

if [[ ! -x "$TOOL_LOGGING_HOOK" ]]; then
    echo "ERROR: tool-logging.sh not found or not executable at: $TOOL_LOGGING_HOOK" >&2
    exit 1
fi

# macOS-compatible millisecond timestamp (date +%s%N unavailable on macOS)
_get_ms() {
    local _ns
    _ns=$(date +%s%N 2>/dev/null) || _ns=""
    if [[ -n "$_ns" && "$_ns" != *N* ]]; then
        echo $(( _ns / 1000000 ))
    else
        python3 -c 'import time;print(int(time.time()*1e3))' 2>/dev/null || echo 0
    fi
}

# Synthetic JSON input for tool-logging.sh
SYNTHETIC_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello"},"session_id":"bench-session"}'

# Check if logging is enabled
_logging_status="disabled"
[[ -f "$HOME/.claude/tool-logging-enabled" ]] && _logging_status="enabled"

echo "Benchmarking tool-logging.sh ($ITERATIONS iterations, logging=$_logging_status)"
echo ""

# Run benchmark for a given mode (pre or post)
_benchmark_mode() {
    local mode="$1"
    local -a timings=()

    for (( i=1; i<=ITERATIONS; i++ )); do
        local _start _end _elapsed
        _start=$(_get_ms)
        printf '%s' "$SYNTHETIC_INPUT" | bash "$TOOL_LOGGING_HOOK" "$mode" >/dev/null 2>/dev/null || true
        _end=$(_get_ms)
        _elapsed=$((_end - _start))
        timings+=("$_elapsed")
    done

    # Sort timings
    local sorted
    sorted=$(printf '%s\n' "${timings[@]}" | sort -n)

    local count=${#timings[@]}
    local total=0
    local min_val max_val

    min_val=$(echo "$sorted" | head -1)
    max_val=$(echo "$sorted" | tail -1)

    for t in "${timings[@]}"; do
        total=$((total + t))
    done

    local avg=$((total / count))

    # p95: index = ceil(0.95 * count)
    local p95_idx=$(( (count * 95 + 99) / 100 ))
    [[ $p95_idx -lt 1 ]] && p95_idx=1
    [[ $p95_idx -gt $count ]] && p95_idx=$count
    local p95_val
    p95_val=$(echo "$sorted" | sed -n "${p95_idx}p")

    printf '%s mode:\n' "$mode"
    printf '  min: %dms\n' "$min_val"
    printf '  avg: %dms\n' "$avg"
    printf '  max: %dms\n' "$max_val"
    printf '  p95: %dms\n' "$p95_val"
    echo ""
}

_benchmark_mode "pre"
_benchmark_mode "post"

echo "Done. ($ITERATIONS iterations each)"
