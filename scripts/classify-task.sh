#!/usr/bin/env bash
# classify-task.sh — Classify beads tasks for /sprint batch planning.
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

# Resolve Python — prefer poetry env, fall back to system python3
if [ -f "$REPO_ROOT/app/poetry.lock" ]; then
    PYTHON="$(cd "$REPO_ROOT/app" && poetry env info -e 2>/dev/null || echo "python3")"
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
    while IFS= read -r tid; do
        [ -n "$tid" ] && task_ids+=("$tid")
    done < <(bd ready --parent="$epic_id" --json 2>/dev/null \
        | "$PYTHON" -c "import sys,json; [print(t['id']) for t in json.load(sys.stdin)]" 2>/dev/null || true)

    if [ ${#task_ids[@]} -eq 0 ]; then
        echo "[]"
        exit 0
    fi
else
    task_ids=("$@")
fi

# --- Collect task JSON via bd show ---
# bd show --json returns a JSON array (e.g. [{...}]) even for a single issue.
# Unwrap to the first element so the outer tasks_json array contains plain objects.
tasks_json="["
first=true
for task_id in "${task_ids[@]}"; do
    raw=$(bd show "$task_id" --json 2>/dev/null || echo "")
    if [ -z "$raw" ]; then
        entry="{\"id\":\"$task_id\",\"error\":\"Task not found\"}"
    else
        entry=$("$PYTHON" -c "import sys,json; d=json.loads(sys.stdin.read()); print(json.dumps(d[0] if isinstance(d,list) else d))" <<< "$raw" 2>/dev/null || echo "{\"id\":\"$task_id\",\"error\":\"Parse error\"}")
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
