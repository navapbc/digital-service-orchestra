#!/usr/bin/env bash
# classify-task.sh — Classify tasks for /sprint batch planning.
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
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Source config-paths.sh for CFG_APP_DIR
_classify_config_paths="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/hooks/lib/config-paths.sh"
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

if [ "$1" = "--from-epic" ]; then
    epic_id="${2:?Missing epic ID}"
    # Use tk ready to list open/in-progress tickets, then filter by parent field
    # (tk ready does not support --parent, so we filter via file-based grep)
    while IFS= read -r tid; do
        [ -n "$tid" ] && task_ids+=("$tid")
    done < <(tk ready 2>/dev/null | awk '{print $1}' \
        | while read -r id; do
            ticket_file="$(git rev-parse --show-toplevel)/.tickets/$id.md"
            if [ -f "$ticket_file" ] && grep -q "parent: $epic_id" "$ticket_file" 2>/dev/null; then
                echo "$id"
            fi
          done || true)

    if [ ${#task_ids[@]} -eq 0 ]; then
        echo "[]"
        exit 0
    fi
else
    task_ids=("$@")
fi

# --- Collect task JSON via tk show ---
# tk show returns markdown output which we parse into a JSON object.
tasks_json="["
first=true
for task_id in "${task_ids[@]}"; do
    raw=$(tk show "$task_id" 2>/dev/null || echo "")
    if [ -z "$raw" ]; then
        entry="{\"id\":\"$task_id\",\"error\":\"Task not found\"}"
    else
        entry=$( echo "$raw" | "$PYTHON" -c "
import sys, re, json
content = sys.stdin.read()
# Extract title from first # heading
title_match = re.search(r'^# (.+)', content, re.MULTILINE)
# Extract type from YAML front-matter (e.g. 'type: bug')
type_match = re.search(r'^type:\s*(\S+)', content, re.MULTILINE)
obj = {
    'id': sys.argv[1],
    'title': title_match.group(1) if title_match else '',
    'task_type': type_match.group(1) if type_match else '',
    'raw': content,
}
print(json.dumps(obj))
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
