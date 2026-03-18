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

# _extract_category_details: extract error details for a category as markdown
# Args: $1=counter_file $2=category
# Outputs markdown-formatted error details to stdout
_extract_category_details() {
    local counter_file="$1"
    local category="$2"
    python3 - "$counter_file" "$category" <<'PYEOF' 2>/dev/null
import json, sys

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

# Show up to 20 most recent entries; note if truncated
total = len(errors)
shown = errors[-20:]
if total > 20:
    print(f"Showing most recent 20 of {total} occurrences.\n")

print("| # | Timestamp | Tool | Input Summary | Error Message |")
print("|---|-----------|------|---------------|---------------|")
for i, e in enumerate(shown, 1):
    ts = e.get('timestamp', 'N/A')
    tool = e.get('tool_name', 'N/A')
    summary = e.get('input_summary', 'N/A').replace('|', '\\|')[:80]
    msg = e.get('error_message', 'N/A').replace('|', '\\|')[:120]
    print(f"| {i} | {ts} | {tool} | {summary} | {msg} |")
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
