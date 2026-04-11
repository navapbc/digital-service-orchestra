#!/usr/bin/env bash
# classify-task.sh — Classify tasks for /dso:sprint batch planning.
#
# Uses weighted profile scoring via classify-task.py to select the best
# sub-agent type, model, and priority for each task.
#
# Usage:
#   classify-task.sh <task-id>              # Classify a single task
#   classify-task.sh <id1> <id2> <id3>      # Classify multiple tasks
#   classify-task.sh --from-epic <epic-id>  # Classify all ready children
#   classify-task.sh --test                 # Run regression tests
#
# Output: JSON array of classification objects to stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"

# Source config-paths.sh for CFG_APP_DIR
_classify_config_paths="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"
[[ -f "$_classify_config_paths" ]] && source "$_classify_config_paths"

# Resolve Python — prefer poetry env, fall back to system python3
if [ -f "$REPO_ROOT/${CFG_APP_DIR:-app}/poetry.lock" ]; then
    PYTHON="$(cd "$REPO_ROOT/${CFG_APP_DIR:-app}" && poetry env info -e 2>/dev/null || echo "python3")"
else
    PYTHON="python3"
fi

SCORER="$SCRIPT_DIR/classify-task.py"

# --- Test mode passthrough ---
if [ "${1:-}" = "--test" ]; then
    exec "$PYTHON" "$SCORER" --test
fi

# --- Collect task IDs ---
if [ $# -eq 0 ]; then
    echo "Usage: classify-task.sh <task-id>..."
    echo "       classify-task.sh --from-epic <epic-id>"
    echo "       classify-task.sh --test"
    exit 2
fi

task_ids=()

# Resolve ticket CLI once, before both the --from-epic and direct-task-ID paths.
TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"

if [ "$1" = "--from-epic" ]; then
    epic_id="${2:?Missing epic ID}"

    # Use v3 ticket list + filter by parent_id and open/in_progress status.
    while IFS= read -r tid; do
        [ -n "$tid" ] && task_ids+=("$tid")
    done < <("$TICKET_CMD" list 2>/dev/null | python3 -c "
import json, sys
tickets = json.load(sys.stdin)
epic_id = sys.argv[1]
for t in tickets:
    if t.get('parent_id') == epic_id and t.get('status') in ('open', 'in_progress'):
        print(t['ticket_id'])
" "$epic_id" || true)

    if [ ${#task_ids[@]} -eq 0 ]; then
        echo "[]"
        exit 0
    fi
else
    task_ids=("$@")
fi

# --- Collect task JSON via ticket show ---
# ticket show returns JSON which we parse into the expected classification object.
tasks_json="["
first=true
for task_id in "${task_ids[@]}"; do
    raw=$("$TICKET_CMD" show "$task_id" 2>/dev/null || echo "")
    if [ -z "$raw" ]; then
        entry="{\"id\":\"$task_id\",\"error\":\"Task not found\"}"
    else
        entry=$( echo "$raw" | "$PYTHON" -c "
import sys, json
content = sys.stdin.read()
try:
    d = json.loads(content)
    title = d.get('title', '')
    task_type = d.get('ticket_type', '')
    obj = {
        'id': sys.argv[1],
        'title': title,
        'task_type': task_type,
        'raw': json.dumps(d),
    }
    print(json.dumps(obj))
except Exception:
    print(json.dumps({'id': sys.argv[1], 'error': 'Parse error'}))
" "$task_id" 2>/dev/null || echo "{\"id\":\"$task_id\",\"error\":\"Parse error\"}" )
    fi

    if $first; then
        first=false
    else
        tasks_json+=","
    fi
    tasks_json+="$entry"
done
tasks_json+="]"

# --- Pipe to Python scorer ---
echo "$tasks_json" | "$PYTHON" "$SCORER"
