#!/usr/bin/env bash
# cross-epic-scan-prep.sh — perform Steps 2.25a–2.25d of cross-epic-scan.md
# inside a single bash invocation, so the brainstorm orchestrator does not
# absorb every candidate epic's description into its working context
# (bug e253-f62a).
#
# What this script does:
#   1. Fetches all open/in_progress epics
#   2. Filters out the current epic by --epic-id
#   3. Loads each candidate's description via `ticket show`
#   4. Extracts approach_summary (first 1500 chars of description) and
#      success_criteria (lines under a "Success Criteria" / "Done" heading)
#   5. Partitions into batches of 5
#   6. Writes batch payloads to <out_dir>/batch_<N>.json
#   7. Runs agent-batch-lifecycle.sh pre-check and emits MAX_AGENTS
#
# Output (stdout): structured key=value lines the orchestrator parses:
#   CANDIDATE_COUNT=<int>
#   BATCH_COUNT=<int>
#   BATCH_FILES=<comma-separated paths>     # empty if CANDIDATE_COUNT==0
#   MAX_AGENTS=<int|unlimited>
#   STATUS=ok|skipped:no_candidates|skipped:usage_paused
#
# Usage:
#   cross-epic-scan-prep.sh --epic-id <current_id> \
#                            --new-epic-payload <path-to-new-epic.json> \
#                            --out-dir <dir>
#
# The new_epic payload is read by the orchestrator from session state and
# written to a path of its choice; this script READS that file when
# assembling each batch JSON (the new_epic header is embedded once per
# batch). The orchestrator owns the lifecycle of the payload file.

set -euo pipefail

EPIC_ID=""
NEW_EPIC_PAYLOAD=""
OUT_DIR=""
BATCH_SIZE=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --epic-id) shift; EPIC_ID="${1:-}" ;;
        --new-epic-payload) shift; NEW_EPIC_PAYLOAD="${1:-}" ;;
        --out-dir) shift; OUT_DIR="${1:-}" ;;
        --batch-size) shift; BATCH_SIZE="${1:-5}" ;;
        -h|--help)
            grep -E '^# ' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

[[ -z "$EPIC_ID" ]] && { echo "ERROR: --epic-id is required" >&2; exit 2; }
[[ -z "$NEW_EPIC_PAYLOAD" ]] && { echo "ERROR: --new-epic-payload is required" >&2; exit 2; }
[[ -z "$OUT_DIR" ]] && { echo "ERROR: --out-dir is required" >&2; exit 2; }
[[ ! -f "$NEW_EPIC_PAYLOAD" ]] && { echo "ERROR: new-epic-payload file not found: $NEW_EPIC_PAYLOAD" >&2; exit 2; }
[[ ! "$BATCH_SIZE" =~ ^[0-9]+$ ]] || [[ "$BATCH_SIZE" -lt 1 ]] && { echo "ERROR: --batch-size must be a positive integer" >&2; exit 2; }

mkdir -p "$OUT_DIR"

# Allow tests to inject a stub ticket CLI via DSO_TICKET_CMD. We parse it
# into an argv array via shlex so embedded quoting is respected and metachars
# in DSO_TICKET_CMD cannot inject shell commands (review-cycle finding).
mapfile -t TICKET_ARGV < <(python3 -c "
import os, shlex
default = '.claude/scripts/dso ticket'
print('\n'.join(shlex.split(os.environ.get('DSO_TICKET_CMD', default))))
")

# 1+2. Fetch candidates (excluding current epic).
CANDIDATES_JSON=$("${TICKET_ARGV[@]}" list --type=epic --status=open,in_progress --format=llm 2>/dev/null \
    | EPIC_ID="$EPIC_ID" python3 -c "
import json, os, sys
ids = []
current = os.environ.get('EPIC_ID', '')
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        t = json.loads(line)
    except json.JSONDecodeError:
        continue
    tid = t.get('id', '')
    if tid and tid != current:
        ids.append(tid)
print(json.dumps(ids))
")
CANDIDATE_COUNT=$(echo "$CANDIDATES_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

# Throttle check (cheap; do it before the expensive ticket-show loop).
# Tests can inject a stub via DSO_AGENT_BATCH_LIFECYCLE to exercise the
# MAX_AGENTS=0 (usage_paused) path.
PLUGIN_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIFECYCLE_SCRIPT="${DSO_AGENT_BATCH_LIFECYCLE:-$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh}"
MAX_AGENTS="unlimited"
if [[ -x "$LIFECYCLE_SCRIPT" ]]; then
    PRE=$(bash "$LIFECYCLE_SCRIPT" pre-check 2>/dev/null || echo "MAX_AGENTS: unlimited")
    MAX_AGENTS=$(echo "$PRE" | grep "^MAX_AGENTS:" | awk '{print $2}')
    MAX_AGENTS="${MAX_AGENTS:-unlimited}"
fi

if [[ "$MAX_AGENTS" == "0" ]]; then
    printf 'CANDIDATE_COUNT=%s\nBATCH_COUNT=0\nBATCH_FILES=\nMAX_AGENTS=0\nSTATUS=skipped:usage_paused\n' "$CANDIDATE_COUNT"
    exit 0
fi

if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then
    printf 'CANDIDATE_COUNT=0\nBATCH_COUNT=0\nBATCH_FILES=\nMAX_AGENTS=%s\nSTATUS=skipped:no_candidates\n' "$MAX_AGENTS"
    exit 0
fi

# 3+4. Load each candidate, extract approach + SC, write a per-epic JSON
# fragment to a working file. Use a single python process for the parsing
# loop so we don't fork per epic.
WORK_FILE=$(mktemp "$OUT_DIR/candidates.XXXXXX.json")

# Pass TICKET_ARGV as JSON to the python loader so it receives the exact
# argv list rather than re-parsing a string (review-cycle finding: `.split()`
# is lossy on quoted commands and breaks on executable paths with spaces).
TICKET_ARGV_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "${TICKET_ARGV[@]}")

python3 - "$WORK_FILE" "$EPIC_ID" "$CANDIDATES_JSON" "$TICKET_ARGV_JSON" <<'PYEOF'
import json, re, subprocess, sys

work_path, epic_id, candidates_json, ticket_argv_json = sys.argv[1:5]
candidate_ids = json.loads(candidates_json)
ticket_argv = json.loads(ticket_argv_json)

def _load_one(tid):
    proc = subprocess.run(
        ticket_argv + ["show", tid],
        check=False, capture_output=True, text=True, timeout=30,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None

def _approach_summary(desc):
    # Pull text under "## Approach" / "## Technical Approach" if present;
    # else first 1500 chars of the description.
    if not desc:
        return ""
    m = re.search(r"(?im)^##\s+(?:Technical\s+)?Approach\s*\n(.+?)(?=^##\s|\Z)",
                  desc, re.DOTALL)
    body = m.group(1).strip() if m else desc.strip()
    return body[:1500]

def _success_criteria(desc):
    # Lines under "## Success Criteria" or "## Done Definition" / "## Done"
    if not desc:
        return []
    m = re.search(r"(?im)^##\s+(?:Success\s+Criteria|Done(?:\s+Definition)?)\s*\n(.+?)(?=^##\s|\Z)",
                  desc, re.DOTALL)
    if not m:
        return []
    lines = []
    for raw in m.group(1).splitlines():
        s = raw.strip()
        if s.startswith(("- ", "* ")):
            lines.append(s[2:].strip())
        elif re.match(r"\d+\.\s", s):
            lines.append(re.sub(r"^\d+\.\s+", "", s).strip())
    return lines

out_epics = []
for tid in candidate_ids:
    t = _load_one(tid)
    if t is None:
        continue
    desc = t.get("description", "") or ""
    out_epics.append({
        "id": tid,
        "title": t.get("title", "")[:200],
        "approach_summary": _approach_summary(desc),
        "success_criteria": _success_criteria(desc),
    })

with open(work_path, "w", encoding="utf-8") as f:
    json.dump(out_epics, f)
PYEOF

# 5+6. Partition into batches and serialize each batch with the new_epic
# header so the classifier sub-agent has all it needs in a single file.
BATCH_FILES=$(python3 - "$WORK_FILE" "$NEW_EPIC_PAYLOAD" "$OUT_DIR" "$BATCH_SIZE" <<'PYEOF'
import json, os, sys

work_path, new_epic_path, out_dir, batch_size = sys.argv[1:5]
batch_size = int(batch_size)

with open(work_path, encoding="utf-8") as f:
    epics = json.load(f)
with open(new_epic_path, encoding="utf-8") as f:
    new_epic = json.load(f)

paths = []
for i in range(0, len(epics), batch_size):
    chunk = epics[i:i + batch_size]
    batch_idx = (i // batch_size) + 1
    payload = {"new_epic": new_epic, "open_epics": chunk}
    p = os.path.join(out_dir, f"batch_{batch_idx:03d}.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(payload, f)
    paths.append(p)
print(",".join(paths))
PYEOF
)

BATCH_COUNT=$(awk -F, '{print NF * ($1 != "")}' <<<"$BATCH_FILES")

printf 'CANDIDATE_COUNT=%s\nBATCH_COUNT=%s\nBATCH_FILES=%s\nMAX_AGENTS=%s\nSTATUS=ok\n' \
    "$CANDIDATE_COUNT" "$BATCH_COUNT" "$BATCH_FILES" "$MAX_AGENTS"
