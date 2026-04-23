#!/usr/bin/env bash
# preconditions-benchmark.sh
# Measures p95 latency for each preconditions pipeline stage.
#
# Usage:
#   preconditions-benchmark.sh [--iterations=N] [--output=json|text]
#
# Flags:
#   --iterations=N   Number of iterations per stage (default: 10)
#   --output=FORMAT  Output format: json (default) or text
#
# Output (JSON): array of {"stage":"<name>","p95_ms":<float>,"samples":<int>}
# One object per stage in order:
#   write_preconditions, read_latest_preconditions, validate_preconditions,
#   compact_preconditions, classify_depth
#
# Exit codes:
#   0 — success
#   1 — argument error

set -uo pipefail

_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

# ── Argument parsing ─────────────────────────────────────────────────────────
_ITERATIONS=10
_OUTPUT_FORMAT="json"

for _arg in "$@"; do
    case "$_arg" in
        --iterations=*)
            _ITERATIONS="${_arg#--iterations=}"
            ;;
        --output=*)
            _OUTPUT_FORMAT="${_arg#--output=}"
            ;;
        *)
            echo "ERROR: unknown argument: $_arg" >&2
            echo "Usage: preconditions-benchmark.sh [--iterations=N] [--output=json|text]" >&2
            exit 1
            ;;
    esac
done

if [[ "$_ITERATIONS" -lt 1 ]] 2>/dev/null; then
    echo "ERROR: --iterations must be a positive integer" >&2
    exit 1
fi

# ── Setup temp environment ────────────────────────────────────────────────────
_TMPDIR=$(mktemp -d)
_TRACKER_DIR="$_TMPDIR/.tickets-tracker"
_TICKET_ID="bench-$(date +%s)"
_TICKET_DIR="$_TRACKER_DIR/$_TICKET_ID"
mkdir -p "$_TICKET_DIR"

# ── Timing helper ─────────────────────────────────────────────────────────────
# _time_ms: prints elapsed milliseconds for a command
_time_ms() {
    local start_ns
    local end_ns
    start_ns=$(python3 -c "import time; print(int(time.monotonic() * 1e9))" 2>/dev/null || date +%s%N 2>/dev/null || echo 0)
    "$@" >/dev/null 2>&1 || true
    end_ns=$(python3 -c "import time; print(int(time.monotonic() * 1e9))" 2>/dev/null || date +%s%N 2>/dev/null || echo 0)
    python3 -c "print(round(($end_ns - $start_ns) / 1e6, 3))" 2>/dev/null || echo "0"
}

# ── Stage implementations (lightweight stubs for benchmarking) ───────────────

_bench_write_preconditions() {
    local ts
    ts=$(python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null || echo "$(date +%s)000")
    local uuid
    uuid=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])" 2>/dev/null || echo "deadbeef")
    local event_file="$_TICKET_DIR/${ts}-${uuid}-PRECONDITIONS.json"
    python3 -c "
import json, sys
event = {
    'event_type': 'PRECONDITIONS',
    'gate_name': 'benchmark-gate',
    'session_id': 'bench-session',
    'worktree_id': 'bench-worktree',
    'tier': 'standard',
    'timestamp': int('$ts'),
    'data': {},
    'schema_version': '2',
    'manifest_depth': 'standard'
}
with open('$event_file', 'w') as f:
    json.dump(event, f)
"
}

_bench_read_latest_preconditions() {
    # Read most recent PRECONDITIONS event for the ticket
    local latest
    latest=$(find "$_TICKET_DIR" -name "*-PRECONDITIONS.json" | sort | tail -1)
    if [[ -n "$latest" ]]; then
        python3 -c "import json; json.load(open('$latest'))" 2>/dev/null || true
    fi
}

_bench_validate_preconditions() {
    # Check if preconditions-validator.sh exists; if not, simulate lightweight validation
    local validator="$_PLUGIN_ROOT/scripts/preconditions-validator.sh"
    if [[ -x "$validator" ]]; then
        bash "$validator" --ticket-id="$_TICKET_ID" --tracker-dir="$_TRACKER_DIR" 2>/dev/null || true
    else
        # Simulate: check latest event is valid JSON with required fields
        local latest
        latest=$(find "$_TICKET_DIR" -name "*-PRECONDITIONS.json" | sort | tail -1)
        if [[ -n "$latest" ]]; then
            python3 -c "
import json
with open('$latest') as f:
    data = json.load(f)
required = ['event_type', 'gate_name', 'session_id', 'tier', 'timestamp', 'schema_version']
assert all(k in data for k in required)
" 2>/dev/null || true
        fi
    fi
}

_bench_compact_preconditions() {
    # Simulate compact: read all events, write summary
    python3 -c "
import json, os, glob
events = []
for path in sorted(glob.glob('$_TICKET_DIR/*-PRECONDITIONS.json')):
    try:
        with open(path) as f:
            events.append(json.load(f))
    except Exception:
        pass
# Write compact summary
summary = {'event_count': len(events), 'latest_tier': events[-1]['tier'] if events else None}
with open('$_TICKET_DIR/.compact-summary.json', 'w') as f:
    json.dump(summary, f)
" 2>/dev/null || true
}

_bench_classify_depth() {
    # Check if preconditions-depth-classifier.sh exists; if not, simulate
    local classifier="$_PLUGIN_ROOT/scripts/preconditions-depth-classifier.sh"
    if [[ -x "$classifier" ]]; then
        bash "$classifier" --complexity=MODERATE 2>/dev/null || true
    else
        # Simulate: map TRIVIAL/MODERATE/COMPLEX → manifest_depth
        python3 -c "
mapping = {'TRIVIAL': 'minimal', 'MODERATE': 'standard', 'COMPLEX': 'deep'}
print(mapping.get('MODERATE', 'standard'))
" 2>/dev/null || true
    fi
}

# ── Benchmark runner ─────────────────────────────────────────────────────────
_run_stage() {
    local stage_name="$1"
    local stage_fn="$2"
    local iterations="$3"
    local -a samples=()

    for _ in $(seq 1 "$iterations"); do
        local elapsed
        elapsed=$(_time_ms "$stage_fn")
        samples+=("$elapsed")
    done

    # Compute p95 via Python
    local samples_str
    samples_str=$(printf '%s\n' "${samples[@]}" | tr '\n' ',')
    local p95
    p95=$(python3 -c "
import statistics
samples = [float(x) for x in '$samples_str'.rstrip(',').split(',') if x]
samples.sort()
n = len(samples)
if n == 0:
    print('0.0')
elif n == 1:
    print(samples[0])
else:
    idx = int(0.95 * n)
    if idx >= n:
        idx = n - 1
    print(round(samples[idx], 3))
" 2>/dev/null || echo "0.0")

    echo "{\"stage\":\"$stage_name\",\"p95_ms\":$p95,\"samples\":$iterations}"
}

# Pre-populate with a few events so reads/validates have data
for _i in $(seq 1 3); do
    _bench_write_preconditions
done

# ── Run all stages ────────────────────────────────────────────────────────────
_RESULTS=()
_RESULTS+=("$(_run_stage "write_preconditions" "_bench_write_preconditions" "$_ITERATIONS")")
_RESULTS+=("$(_run_stage "read_latest_preconditions" "_bench_read_latest_preconditions" "$_ITERATIONS")")
_RESULTS+=("$(_run_stage "validate_preconditions" "_bench_validate_preconditions" "$_ITERATIONS")")
_RESULTS+=("$(_run_stage "compact_preconditions" "_bench_compact_preconditions" "$_ITERATIONS")")
_RESULTS+=("$(_run_stage "classify_depth" "_bench_classify_depth" "$_ITERATIONS")")

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "$_TMPDIR"

# ── Output ────────────────────────────────────────────────────────────────────
if [[ "$_OUTPUT_FORMAT" == "json" ]]; then
    python3 -c "
import json, sys
results = [json.loads(line) for line in sys.stdin if line.strip()]
print(json.dumps(results, indent=2))
" <<PYINPUT
$(printf '%s\n' "${_RESULTS[@]}")
PYINPUT
elif [[ "$_OUTPUT_FORMAT" == "text" ]]; then
    printf "%-35s %10s %10s\n" "Stage" "p95_ms" "Samples"
    printf "%-35s %10s %10s\n" "-----" "------" "-------"
    for _result in "${_RESULTS[@]}"; do
        _stage=$(echo "$_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['stage'])" 2>/dev/null || echo "?")
        _p95=$(echo "$_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['p95_ms'])" 2>/dev/null || echo "?")
        _samples=$(echo "$_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['samples'])" 2>/dev/null || echo "?")
        printf "%-35s %10s %10s\n" "$_stage" "$_p95" "$_samples"
    done
else
    echo "ERROR: unknown output format: $_OUTPUT_FORMAT" >&2
    exit 1
fi
