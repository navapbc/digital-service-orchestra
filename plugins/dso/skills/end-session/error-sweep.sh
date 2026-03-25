#!/usr/bin/env bash
# skills/end-session/error-sweep.sh
# Library providing sweep_tool_errors() and sweep_validation_failures() for the /dso:end skill (Step 2.9).
#
# Reads ~/.claude/tool-error-counter.json, iterates categories in .index where
# count >= 50, and creates a deduplicated bug ticket via `tk create` for each.
# Includes error details in the ticket description and removes processed entries
# from the counter file to prevent re-creation.
#
# Counter JSON structure: {"index": {"category_name": count, ...}, "errors": [...]}
#
# Usage:
#   source "${CLAUDE_PLUGIN_ROOT}/skills/end-session/error-sweep.sh"
#   sweep_tool_errors

THRESHOLD=50

# Categories that are normal operational noise — counts are tracked but no ticket is created.
# Source of truth: hooks/track-tool-errors.sh (NOISE_CATEGORIES variable).
NOISE_CATEGORIES="file_not_found command_exit_nonzero"

# _extract_category_details: extract deduplicated error details for a category as markdown
# Args: $1=counter_file $2=category
# Outputs markdown-formatted error details to stdout, grouped by unique
# (tool_name, error_message) signature with occurrence counts.
_extract_category_details() {
    local counter_file="$1"
    local category="$2"
    python3 - "$counter_file" "$category" <<'PYEOF' 2>/dev/null
import json, sys
from collections import OrderedDict

counter_path = sys.argv[1]
category = sys.argv[2]

try:
    with open(counter_path, 'r') as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

errors = [e for e in data.get('errors', []) if e.get('category') == category]
if not errors:
    print("No detailed error entries recorded.")
    sys.exit(0)

# Deduplicate by (tool_name, error_message) — keep first/last timestamps and count
groups = OrderedDict()
for e in errors:
    key = (e.get('tool_name', 'N/A'), e.get('error_message', 'N/A'))
    if key not in groups:
        groups[key] = {
            'tool_name': key[0],
            'error_message': key[1],
            'input_summary': e.get('input_summary', 'N/A'),
            'first_seen': e.get('timestamp', 'N/A'),
            'last_seen': e.get('timestamp', 'N/A'),
            'count': 0,
        }
    groups[key]['last_seen'] = e.get('timestamp', 'N/A')
    groups[key]['count'] += 1

total = len(errors)
unique = len(groups)
print(f"{total} occurrences, {unique} unique error signature(s).\n")

# Show up to 10 unique signatures, sorted by count descending
signatures = sorted(groups.values(), key=lambda g: g['count'], reverse=True)[:10]

print("| # | Tool | Error Message | Count | First Seen | Last Seen |")
print("|---|------|---------------|-------|------------|-----------|")
for i, g in enumerate(signatures, 1):
    tool = g['tool_name']
    msg = g['error_message'].replace('|', '\\|')[:120]
    count = g['count']
    first = g['first_seen']
    last = g['last_seen']
    print(f"| {i} | {tool} | {msg} | {count} | {first} | {last} |")
PYEOF
}

# _remove_category_from_counter: remove a category's entries and index from the counter file
# Args: $1=counter_file $2=category
_remove_category_from_counter() {
    local counter_file="$1"
    local category="$2"
    local updated
    updated=$(python3 - "$counter_file" "$category" <<'PYEOF' 2>/dev/null
import json, sys

counter_path = sys.argv[1]
category = sys.argv[2]

try:
    with open(counter_path, 'r') as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

# Remove entries matching this category
data['errors'] = [e for e in data.get('errors', []) if e.get('category') != category]

# Remove category from index
data.get('index', {}).pop(category, None)

print(json.dumps(data))
PYEOF
    ) || return 0
    echo "$updated" > "$counter_file"
}

# sweep_tool_errors
# Iterate all categories in ~/.claude/tool-error-counter.json with count >= THRESHOLD.
# For each, check if an open bug ticket already exists (dedup). If not, create one
# with error details in the description, then remove processed entries from the counter.
# Exits 0 in all cases (missing/malformed counter file is not an error).
sweep_tool_errors() {
    local _SWEEP_DIR; _SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _MONITORING; _MONITORING=$(bash "$_SWEEP_DIR/../../scripts/read-config.sh" monitoring.tool_errors 2>/dev/null || echo "false")
    [[ "$_MONITORING" != "true" ]] && return 0
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

    while IFS=$'\t' read -r category count; do
        [[ -z "$category" ]] && continue

        # Skip noise categories — they are high-frequency operational events, not actionable bugs
        local _is_noise=false
        for _nc in $NOISE_CATEGORIES; do
            if [[ "$category" == "$_nc" ]]; then _is_noise=true; break; fi
        done
        if [[ "$_is_noise" == "true" ]]; then
            # Still drain noise entries to prevent unbounded growth
            _remove_category_from_counter "$counter_file" "$category"
            continue
        fi

        local ticket_title="Recurring tool error: $category ($count occurrences)"

        # Dedup: re-query open bugs immediately before create to minimize race window
        # when concurrent sub-agents call sweep_tool_errors() simultaneously.
        local open_bugs
        open_bugs=$(tk list --type bug --status open 2>/dev/null || true)
        if echo "$open_bugs" | grep -qF "Recurring tool error: $category"; then
            # Still drain entries to prevent re-creation on next sweep
            _remove_category_from_counter "$counter_file" "$category"
            continue
        fi

        # Extract error details for the ticket description
        local details
        details=$(_extract_category_details "$counter_file" "$category")

        local description="## Error Details

${details}"

        tk create "$ticket_title" -t bug -p 2 -d "$description"

        # Remove processed entries from counter to prevent re-creation
        _remove_category_from_counter "$counter_file" "$category"
    done <<< "$categories_output"

    return 0
}

# sweep_validation_failures
# Reads ARTIFACTS_DIR/untracked-validation-failures.log, extracts unique failure
# categories, deduplicates against existing open bug tickets, and creates a bug
# ticket for each untracked category.
#
# ARTIFACTS_DIR must be set by the caller (session-scoped; interrupted sessions
# lose data — accepted limitation).
# Exits 0 in all cases (missing/empty log is not an error).
sweep_validation_failures() {
    local log_file="${ARTIFACTS_DIR:-}/untracked-validation-failures.log"

    # Gracefully skip if log file is absent
    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    # Collect unique non-empty categories from the log
    local categories=()
    while IFS= read -r line; do
        # Strip leading/trailing whitespace
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ -z "$trimmed" ]] && continue

        # Deduplicate in-array
        local already=false
        local c
        for c in "${categories[@]+"${categories[@]}"}"; do
            if [[ "$c" == "$trimmed" ]]; then already=true; break; fi
        done
        if [[ "$already" == "false" ]]; then
            categories+=("$trimmed")
        fi
    done < "$log_file"

    # Nothing to do if no categories found
    if [[ "${#categories[@]}" -eq 0 ]]; then
        return 0
    fi

    for category in "${categories[@]}"; do
        local ticket_title="Untracked validation failure: $category"

        # Dedup: check for existing open bug ticket before creating
        local open_bugs
        open_bugs=$(tk list --type bug --status open 2>/dev/null || true)
        if echo "$open_bugs" | grep -qF "Untracked validation failure: $category"; then
            continue
        fi

        tk create "$ticket_title" -t bug -p 2
    done

    return 0
}
