#!/usr/bin/env bash
set -euo pipefail
# scripts/analyze-exit-144.sh
# Companion analysis script for exit-144 forensic logger.
#
# Parses the JSONL log produced by the PostToolUse forensic hook and reports:
#   1. Top 5 commands by exit-144 frequency
#   2. Cause breakdown (timeout vs cancellation, with percentages)
#   3. Elapsed time statistics (min, max, median, p90)
#
# Usage:
#   analyze-exit-144.sh [--file <path>]
#
# Defaults to $(get_artifacts_dir)/exit-144-forensics.jsonl if --file is omitted.

set -euo pipefail

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo ".")}"

# Parse arguments
LOG_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)
            LOG_FILE="$2"
            shift 2
            ;;
        *)
            echo "Usage: analyze-exit-144.sh [--file <path>]" >&2
            exit 1
            ;;
    esac
done

# Default log file location
if [[ -z "$LOG_FILE" ]]; then
    # Source deps.sh for get_artifacts_dir if available
    if [[ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh" ]]; then
        source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
        LOG_FILE="$(get_artifacts_dir)/exit-144-forensics.jsonl"
    else
        LOG_FILE="${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-/tmp}/exit-144-forensics.jsonl"
    fi
fi

# Check if file exists and is non-empty
if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    echo "No exit-144 events recorded."
    exit 0
fi

# Use python3 for JSONL parsing and analysis
python3 - "$LOG_FILE" <<'PYTHON'
import json
import sys
import statistics

log_file = sys.argv[1]

entries = []
malformed = 0

with open(log_file, 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            entries.append(entry)
        except json.JSONDecodeError:
            malformed += 1

if not entries:
    print("No exit-144 events recorded.")
    if malformed > 0:
        print(f"Skipped {malformed} malformed line{'s' if malformed != 1 else ''}.")
    sys.exit(0)

if malformed > 0:
    print(f"Skipped {malformed} malformed line{'s' if malformed != 1 else ''}.")
    print()

# --- Top 5 commands by frequency ---
cmd_counts = {}
for e in entries:
    cmd = e.get('command', '<unknown>')
    cmd_counts[cmd] = cmd_counts.get(cmd, 0) + 1

sorted_cmds = sorted(cmd_counts.items(), key=lambda x: -x[1])[:5]

print("Top Commands by Exit-144 Frequency")
print("-" * 50)
print(f"{'Command':<35} {'Count':>5}")
print("-" * 50)
for cmd, count in sorted_cmds:
    display = cmd if len(cmd) <= 35 else cmd[:32] + "..."
    print(f"{display:<35} {count:>5}")
print()

# --- Cause breakdown ---
cause_counts = {}
for e in entries:
    cause = e.get('cause', 'unknown')
    cause_counts[cause] = cause_counts.get(cause, 0) + 1

total = len(entries)
print("Cause Breakdown")
print("-" * 40)
for cause in sorted(cause_counts.keys()):
    count = cause_counts[cause]
    pct = (count / total) * 100
    print(f"  {cause:<20} {count:>4}  ({pct:.1f}%)")
print(f"  {'total':<20} {total:>4}")
print()

# --- Elapsed time stats ---
elapsed_values = [e.get('elapsed_s', 0) for e in entries if e.get('elapsed_s', -1) >= 0]

if elapsed_values:
    elapsed_sorted = sorted(elapsed_values)
    median_val = statistics.median(elapsed_sorted)
    p90_idx = int(len(elapsed_sorted) * 0.9)
    if p90_idx >= len(elapsed_sorted):
        p90_idx = len(elapsed_sorted) - 1
    p90_val = elapsed_sorted[p90_idx]

    print("Elapsed Time Stats (seconds)")
    print("-" * 30)
    print(f"  min:    {min(elapsed_values):.1f}")
    print(f"  max:    {max(elapsed_values):.1f}")
    print(f"  median: {median_val:.1f}")
    print(f"  p90:    {p90_val:.1f}")
else:
    print("Elapsed Time Stats: no valid elapsed_s data")
PYTHON
