#!/usr/bin/env bash
# lockpick-workflow/scripts/analyze-precompact-telemetry.sh
#
# Reads ~/.claude/precompact-telemetry.jsonl and outputs a summary.
#
# Usage:
#   analyze-precompact-telemetry.sh [--json] <path-to-telemetry.jsonl>
#
# Flags:
#   --json    Output machine-readable JSON instead of human-readable text
#
# Exit codes:
#   0  Success
#   1  Missing arguments or file not found

set -euo pipefail

JSON_MODE=false

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            JSON_MODE=true
            shift
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    echo "Usage: $(basename "$0") [--json] <telemetry.jsonl>" >&2
    exit 1
fi

TELEMETRY_FILE="$1"

if [[ ! -f "$TELEMETRY_FILE" ]]; then
    echo "Error: file not found: $TELEMETRY_FILE" >&2
    exit 1
fi

exec python3 - "$JSON_MODE" "$TELEMETRY_FILE" <<'PYTHON_EOF'
import json
import sys
from collections import defaultdict
from datetime import datetime

json_mode = sys.argv[1] == "true"
telemetry_file = sys.argv[2]

entries = []
with open(telemetry_file, 'r') as f:
    for line in f:
        line = line.strip()
        if line:
            entries.append(json.loads(line))

total_fires = len(entries)

# Group by session_id
sessions = defaultdict(list)
for e in entries:
    sessions[e['session_id']].append(e)

# Outcome breakdown
outcome_counts = defaultdict(int)
for e in entries:
    outcome_counts[e['hook_outcome']] += 1

# Potentially spurious: context_tokens is null
spurious = [e for e in entries if e.get('context_tokens') is None]

# Time relative to first fire in each session
def parse_ts(ts_str):
    # Handle ISO 8601 with Z suffix
    return datetime.fromisoformat(ts_str.replace('Z', '+00:00'))

session_summaries = []
for sid in sorted(sessions.keys()):
    s_entries = sessions[sid]
    s_entries.sort(key=lambda e: e['timestamp'])
    first_ts = parse_ts(s_entries[0]['timestamp'])

    fires_with_offset = []
    for e in s_entries:
        ts = parse_ts(e['timestamp'])
        offset_secs = int((ts - first_ts).total_seconds())
        fires_with_offset.append({
            'timestamp': e['timestamp'],
            'offset_seconds': offset_secs,
            'hook_outcome': e['hook_outcome'],
            'exit_reason': e['exit_reason'],
            'context_tokens': e.get('context_tokens'),
            'duration_ms': e['duration_ms'],
            'session_id': sid,
        })

    session_summaries.append({
        'session_id': sid,
        'fire_count': len(s_entries),
        'fires': fires_with_offset,
    })

if json_mode:
    output = {
        'total_fires': total_fires,
        'sessions': session_summaries,
        'outcome_breakdown': dict(outcome_counts),
        'potentially_spurious': [
            {
                'timestamp': e['timestamp'],
                'session_id': e['session_id'],
                'context_tokens': e.get('context_tokens'),
                'hook_outcome': e['hook_outcome'],
            }
            for e in spurious
        ],
    }
    print(json.dumps(output, indent=2))
else:
    print(f'Pre-compact Telemetry Summary')
    print(f'═' * 50)
    print(f'Total fires: {total_fires}')
    print()

    print('Outcome Breakdown:')
    for outcome, count in sorted(outcome_counts.items()):
        print(f'  {outcome}: {count}')
    print()

    print('Sessions:')
    for s in session_summaries:
        print(f'  {s["session_id"]} ({s["fire_count"]} fires):')
        for fire in s['fires']:
            offset = fire['offset_seconds']
            marker = ' [potentially spurious]' if fire['context_tokens'] is None else ''
            print(f'    +{offset}s  {fire["hook_outcome"]:15s}  {fire["exit_reason"]}{marker}')
    print()

    if spurious:
        print(f'Potentially Spurious Entries (null context_tokens): {len(spurious)}')
        for e in spurious:
            print(f'  - {e["timestamp"]}  session={e["session_id"]}')
PYTHON_EOF
