#!/usr/bin/env bash
set -euo pipefail
# scripts/enrich-file-impact.sh
# Enrich a ticket with a ## File Impact section using haiku model.
#
# Usage:
#   enrich-file-impact.sh [--dry-run] <ticket-id>
#
# If the ticket already has a file impact section, exits 0 with message.
# If ANTHROPIC_API_KEY is unset, exits 0 with warning (graceful degradation).
# Uses curl to call Anthropic Messages API directly (no SDK dependency).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."
TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
PLUGIN_SCRIPTS="${SCRIPT_DIR}"

# Source config-paths.sh for portable path resolution
_CONFIG_PATHS="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"
if [ -f "$_CONFIG_PATHS" ]; then
    # shellcheck source=../hooks/lib/config-paths.sh
    source "$_CONFIG_PATHS"
fi

MODEL=$(bash "${SCRIPT_DIR}/resolve-model-id.sh" haiku 2>/dev/null) || {
    echo "ERROR: resolve-model-id.sh failed to resolve haiku model ID" >&2
    exit 1
}
MAX_TOKENS=500
DRY_RUN=false

# Parse args
args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) args+=("$arg") ;;
    esac
done

if [ ${#args[@]} -ne 1 ]; then
    echo "Usage: enrich-file-impact.sh [--dry-run] <ticket-id>" >&2
    exit 1
fi

ID="${args[0]}"

# Load ticket content using the v3 ticket CLI.
output=$("$TICKET_CMD" show "$ID" 2>/dev/null) || output=""
if [ -z "$output" ]; then
    echo "ERROR: Could not load ticket $ID" >&2
    exit 1
fi

# Check if file impact already exists via structured storage API (primary idempotency check)
existing=$("$TICKET_CMD" get-file-impact "$ID" 2>/dev/null || echo "[]")
if [ -n "$existing" ] && [ "$existing" != "[]" ]; then
    echo "File impact already set for $ID (get-file-impact returned non-empty)" >&2
    exit 0
fi

# Fallback idempotency check: look for markdown ## File Impact section in ticket output
# (backward compat — tickets enriched before FILE_IMPACT events were introduced)
has_file_impact=$(echo "$output" | awk '
  tolower($0) ~ /^## file impact/ || tolower($0) ~ /^### files to modify/ { found=1 }
  END { print found+0 }
')

if [ "$has_file_impact" -ge 1 ]; then
    echo "File impact section already present in $ID"
    exit 0
fi

# Check for API key — graceful degradation (skip when dry-run; key not needed)
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ "$DRY_RUN" != true ]; then
    echo "WARNING: ANTHROPIC_API_KEY not set. Cannot enrich file impact for $ID." >&2
    echo "Set ANTHROPIC_API_KEY to enable haiku-based file impact generation." >&2
    exit 0
fi

# Resolve source directories from config (fallback defaults for standalone use)
if [ -x "${PLUGIN_SCRIPTS}/read-config.sh" ]; then
    _config_dirs=$("${PLUGIN_SCRIPTS}/read-config.sh" --list format.source_dirs 2>/dev/null || true)
fi
if [ -z "${_config_dirs:-}" ]; then
    echo "WARNING: read-config.sh unavailable or format.source_dirs empty; using fallback defaults." >&2
    _CFG_APP="${CFG_APP_DIR:-app}"
    _CFG_SRC="${CFG_SRC_DIR:-src}"
    _CFG_TEST="${CFG_TEST_DIR:-tests}"
    _config_dirs="${_CFG_APP}/${_CFG_SRC}"$'\n'"${_CFG_APP}/${_CFG_TEST}"  # fallback defaults
fi

# Get codebase structure for context — split dirs into source vs test
tree_output=""
test_tree=""
while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    full_path="$REPO_ROOT/$dir"
    [ -d "$full_path" ] || continue
    if echo "$dir" | grep -q "test"; then
        # || true prevents SIGPIPE from head -N terminating early on large codebases
        test_tree+=$(find "$full_path" -type f -name "*.py" | sed "s|$REPO_ROOT/||" | sort | head -40 || true)
        test_tree+=$'\n'
    else
        # || true prevents SIGPIPE from head -N terminating early on large codebases
        tree_output+=$(find "$full_path" -type f -name "*.py" | sed "s|$REPO_ROOT/||" | sort | head -80 || true)
        tree_output+=$'\n'
    fi
done <<< "$_config_dirs"

# Extract ticket title and description for the prompt
ticket_title=$(echo "$output" | awk '/^# /{print; exit}')
ticket_body=$(echo "$output" | awk '/^---$/{fm++; next} fm<2{next} {print}')

# Build the prompt — escape for JSON
prompt_text="Given this ticket and codebase structure, list the source and test files most likely to be modified.

TICKET:
${ticket_title}
${ticket_body}

SOURCE FILES:
${tree_output}

TEST FILES:
${test_tree}

Respond with ONLY a markdown section like this (no other text):
## File Impact
- \`path/to/file.py\` - brief reason
- \`path/to/test_file.py\` - brief reason"

# Dry-run: report model, prompt length, and exit before making any API call
if [ "$DRY_RUN" = true ]; then
    prompt_len=${#prompt_text}
    echo "DRY RUN: Would call Anthropic API with model=$MODEL for ticket $ID"
    echo "Prompt length: ${prompt_len} chars"
    exit 0
fi

# Escape the prompt for JSON
json_prompt=$(printf '%s' "$prompt_text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

# Build request body
request_body=$(cat <<ENDJSON
{
  "model": "${MODEL}",
  "max_tokens": ${MAX_TOKENS},
  "messages": [
    {"role": "user", "content": ${json_prompt}}
  ]
}
ENDJSON
)

# Call Anthropic Messages API
response=$(curl -s -m 30 --connect-timeout 10 \
    https://api.anthropic.com/v1/messages \
    -H "content-type: application/json" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -d "$request_body")

# Extract text from response
file_impact=$(echo "$response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if "content" in data and len(data["content"]) > 0:
        print(data["content"][0]["text"])
    elif "error" in data:
        print(f"API Error: {data["error"].get("message", "unknown")}", file=sys.stderr)
        sys.exit(1)
    else:
        print("Unexpected response format", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"Failed to parse response: {e}", file=sys.stderr)
    sys.exit(1)
')

if [ -z "$file_impact" ]; then
    echo "WARNING: Empty response from API for $ID" >&2
    exit 0
fi

# Append file impact to ticket as a COMMENT event via the ticket CLI.
if [ ! -x "$TICKET_CMD" ]; then
    echo "ERROR: ticket CLI not found at $TICKET_CMD" >&2
    exit 1
fi

# Convert markdown file impact response to JSON array for structured storage.
# shellcheck disable=SC2016  # single quotes intentional: python3 script, no shell expansion needed
file_impact_json=$(echo "$file_impact" | python3 -c '
import sys, re, json

text = sys.stdin.read()
entries = []
for line in text.split("\n"):
    line = line.strip()
    m = re.match(r"^[-*]\s+\`?([^\`]+)\`?\s*[-—]?\s*(.*)", line)
    if m:
        path = m.group(1).strip()
        reason = m.group(2).strip() if m.group(2).strip() else "modified"
        if path and ("/" in path or "." in path):
            entries.append({"path": path, "reason": reason})
print(json.dumps(entries))
' 2>/dev/null || echo "[]")

# Store via structured API (primary storage path)
"$TICKET_CMD" set-file-impact "$ID" "$file_impact_json" || {
    echo "ERROR: Failed to set file impact on ticket $ID" >&2
    exit 1
}

# Also store as comment for backward compatibility (markdown readable form)
"$TICKET_CMD" comment "$ID" "$file_impact" || {
    echo "WARNING: Failed to record file impact comment on ticket $ID (set-file-impact succeeded)" >&2
}
echo "File impact section added to $ID (v3 set-file-impact + comment event)"
