#!/usr/bin/env bash
set -euo pipefail
# approach-cycle-state.sh
# Cycle-counter persistence for the /dso:implementation-plan approach
# resolution loop.
#
# Maintains a per-story counter of how many counter-proposal revision
# cycles have been completed, with a 4-hour TTL on the state file.
#
# State file path: /tmp/approach-resolution-<story-id>.json
# State file shape: {"cycle_count": <int>, "story_id": "<id>"}
# TTL: 14400 seconds (4 hours). Older files are treated as fresh start.
#
# Usage:
#   approach-cycle-state.sh read      <story-id>   # prints cycle_count (0 if absent/stale)
#   approach-cycle-state.sh increment <story-id>   # increments and writes; prints new value
#   approach-cycle-state.sh clear     <story-id>   # removes file; prints "cleared"
#
# Exit codes:
#   0 — success
#   1 — usage error

CMD="${1:-}"
STORY_ID="${2:-}"
[[ -z "$CMD" || -z "$STORY_ID" ]] && {
    echo "usage: approach-cycle-state.sh {read|increment|clear} <story-id>" >&2
    exit 1
}

STATE_FILE="/tmp/approach-resolution-${STORY_ID}.json"
TTL=14400

_is_stale() {
    [[ ! -f "$STATE_FILE" ]] && return 0
    local _mtime
    _mtime=$(date -r "$STATE_FILE" +%s 2>/dev/null || echo 0)
    local _now
    _now=$(date +%s)
    (( _now - _mtime > TTL ))
}

_read_count() {
    if _is_stale; then
        rm -f "$STATE_FILE"
        echo 0
        return
    fi
    python3 -c "
import json
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('cycle_count', 0))
except Exception:
    print(0)
" 2>/dev/null || echo 0
}

case "$CMD" in
    read)
        _read_count
        ;;
    increment)
        _current=$(_read_count)
        _new=$(( _current + 1 ))
        # Do NOT swallow write errors — silent failures here corrupt the
        # cycle counter (caller would see N printed without the file persisted).
        python3 -c "
import json
json.dump({'cycle_count': $_new, 'story_id': '$STORY_ID'}, open('$STATE_FILE', 'w'))
"
        echo "$_new"
        ;;
    clear)
        rm -f "$STATE_FILE"
        echo "cleared"
        ;;
    *)
        echo "usage: approach-cycle-state.sh {read|increment|clear} <story-id>" >&2
        exit 1
        ;;
esac
