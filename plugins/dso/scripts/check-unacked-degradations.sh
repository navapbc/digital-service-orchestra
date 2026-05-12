#!/usr/bin/env bash
# Must be called before dso:completion-verifier dispatch in sprint Step 18
set -uo pipefail

story_id="${1:-}"
if [[ -z "$story_id" ]]; then
    echo "Usage: check-unacked-degradations.sh <story_id>" >&2
    exit 1
fi

if [[ -n "${DSO_TICKETS_TRACKER_DIR:-}" ]]; then
    TICKETS_TRACKER_DIR="$DSO_TICKETS_TRACKER_DIR"
else
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "WARN: not in git repo" >&2; exit 0; }
    TICKETS_TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
fi

ticket_dir="$TICKETS_TRACKER_DIR/$story_id"

# Pre-manifest exemption: no PRECONDITIONS files → not yet in preconditions tracking
shopt -s nullglob
preconditions_files=("$ticket_dir"/*-PRECONDITIONS.json)
shopt -u nullglob
if [[ ${#preconditions_files[@]} -eq 0 ]]; then
    exit 0
fi

# Collect degradation decision_ids and acked decision_ids via python3
result=$(python3 - "$ticket_dir" <<'PYEOF'
import sys, json, glob, os

ticket_dir = sys.argv[1]
degradation_ids = set()
acked_ids = set()

for path in glob.glob(os.path.join(ticket_dir, '*-PRECONDITIONS.json')):
    try:
        with open(path) as f:
            ev = json.load(f)
        data = ev.get('data', {})
        if data.get('degradation') is True:
            for did in data.get('decision_ids', []):
                degradation_ids.add(did)
    except Exception:
        pass  # fail-open: skip malformed files

for path in glob.glob(os.path.join(ticket_dir, '*-ACK.json')):
    try:
        with open(path) as f:
            ack = json.load(f)
        for did in ack.get('decision_ids', []):
            acked_ids.add(did)
    except Exception:
        pass  # fail-open

unacked = degradation_ids - acked_ids
for did in sorted(unacked):
    print(did)
PYEOF
) || { echo "WARN: python3 parsing failed" >&2; exit 0; }

if [[ -n "$result" ]]; then
    echo "$result"
    exit 1
fi
exit 0
