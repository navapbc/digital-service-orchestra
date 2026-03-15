#!/usr/bin/env bash
# lockpick-workflow/skills/end-session/error-sweep.sh
# Library providing sweep_tool_errors() for the /end skill (Step 5.75).
#
# Reads ~/.claude/tool-error-counter.json, iterates categories in .index where
# count >= 50, and creates a deduplicated bug ticket via `tk create` for each.
#
# Counter JSON structure: {"index": {"category_name": count, ...}, "errors": [...]}
#
# READ-ONLY: this script never writes to or resets the counter file.
#
# Usage:
#   source "$REPO_ROOT/lockpick-workflow/skills/end-session/error-sweep.sh"
#   sweep_tool_errors

THRESHOLD=50

# sweep_tool_errors
# Iterate all categories in ~/.claude/tool-error-counter.json with count >= THRESHOLD.
# For each, check if an open bug ticket already exists (dedup). If not, create one.
# Exits 0 in all cases (missing/malformed counter file is not an error).
sweep_tool_errors() {
    local counter_file="$HOME/.claude/tool-error-counter.json"

    # Gracefully skip if counter file is absent
    if [[ ! -f "$counter_file" ]]; then
        return 0
    fi

    # Parse categories and counts via python3; output "category count" lines
    local categories_output
    categories_output=$(python3 - "$counter_file" "$THRESHOLD" <<'PYEOF' 2>/dev/null
import json, sys

counter_path = sys.argv[1]
threshold = int(sys.argv[2])

try:
    with open(counter_path, 'r') as f:
        data = json.load(f)
    index = data.get('index', {})
    for category, count in index.items():
        if isinstance(count, (int, float)) and count >= threshold:
            print(f"{category}\t{int(count)}")
except Exception:
    # Malformed JSON or unexpected structure — skip gracefully
    pass
PYEOF
    ) || return 0

    # If no categories at or above threshold, nothing to do
    if [[ -z "$categories_output" ]]; then
        return 0
    fi

    # Get current open bug tickets once for dedup checks
    local open_bugs
    open_bugs=$(tk list --type bug --status open 2>/dev/null || true)

    while IFS=$'\t' read -r category count; do
        [[ -z "$category" ]] && continue

        local ticket_title="Recurring tool error: $category ($count occurrences)"

        # Dedup: skip if an open bug already mentions this category
        if echo "$open_bugs" | grep -qF "Recurring tool error: $category"; then
            continue
        fi

        tk create "$ticket_title" -t bug -p 2
    done <<< "$categories_output"

    return 0
}
