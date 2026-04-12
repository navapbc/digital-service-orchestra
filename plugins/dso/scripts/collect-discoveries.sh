#!/usr/bin/env bash
set -euo pipefail
# scripts/collect-discoveries.sh — Collect and merge agent discovery files.
#
# Reads all .agent-discoveries/<task-id>.json files, validates each against
# the discovery schema, merges them into a single JSON array, and outputs
# the result to stdout.
#
# Discovery file schema:
#   {
#     "task_id": "<string>",
#     "type": "bug|dependency|api_change|convention",
#     "summary": "<string>",
#     "affected_files": ["<path>", ...]
#   }
#
# Options:
#   --format=prompt   Output a markdown-formatted ## PRIOR_BATCH_DISCOVERIES
#                     section suitable for direct inclusion in sub-agent prompts.
#
# Environment:
#   AGENT_DISCOVERIES_DIR   Override the discoveries directory path
#                           (default: $ARTIFACTS_DIR/agent-discoveries/ via get_artifacts_dir)
#
# Behavior:
#   - Empty directory (no .json files): output empty JSON array [] (or empty
#     prompt section for --format=prompt)
#   - Malformed JSON: skip with warning to stderr, continue processing
#   - Missing directory: create it, return empty array
#
# Usage:
#   scripts/collect-discoveries.sh                  # raw JSON array
#   scripts/collect-discoveries.sh --format=prompt  # markdown prompt section

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"

# Source deps.sh for get_artifacts_dir
# Defensive plugin-root resolution: CLAUDE_PLUGIN_ROOT may point to the main repo
# root instead of the plugin subdirectory (e.g., ${CLAUDE_PLUGIN_ROOT}) when called from a
# host project via the dso shim. Validate using plugin.json (always present in the
# plugin dir) and fall back to $SCRIPT_DIR/.. (the plugin dir relative to this script).
# shellcheck source=hooks/lib/deps.sh
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${_PLUGIN_ROOT}/plugin.json" ]] && _PLUGIN_ROOT="$SCRIPT_DIR/.."
source "${_PLUGIN_ROOT}/hooks/lib/deps.sh"

# Resolve discoveries directory
DISCOVERIES_DIR="${AGENT_DISCOVERIES_DIR:-$(get_artifacts_dir)/agent-discoveries}"

# Parse arguments
FORMAT="json"
for arg in "$@"; do
    case "$arg" in
        --format=prompt) FORMAT="prompt" ;;
        --format=json)   FORMAT="json" ;;
        --help|-h)
            echo "Usage: collect-discoveries.sh [--format=prompt|json]"
            echo ""
            echo "Collects .agent-discoveries/*.json files into a merged array."
            echo "  --format=json    (default) Output raw JSON array"
            echo "  --format=prompt  Output markdown ## PRIOR_BATCH_DISCOVERIES section"
            exit 0
            ;;
        *)
            echo "WARNING: Unknown argument: $arg" >&2
            ;;
    esac
done

# Create directory if missing
if [ ! -d "$DISCOVERIES_DIR" ]; then
    mkdir -p "$DISCOVERIES_DIR"
fi

# Collect valid discovery objects
merged="[]"

for json_file in "$DISCOVERIES_DIR"/*.json; do
    # Handle glob that matched nothing (no .json files)
    [ -e "$json_file" ] || continue

    # Validate JSON
    local_obj=$(jq '.' "$json_file" 2>/dev/null) || {
        echo "WARNING: Skipping malformed JSON: $(basename "$json_file")" >&2
        continue
    }

    # Validate schema: must have task_id, type, summary, affected_files
    valid=$(echo "$local_obj" | jq '
        if (.task_id | type) == "string" and
           (.type | type) == "string" and
           (.summary | type) == "string" and
           (.affected_files | type) == "array" and
           (.affected_files | all(type == "string"))
        then 1 else 0 end
    ' 2>/dev/null || echo "0")

    if [ "$valid" != "1" ]; then
        echo "WARNING: Skipping invalid schema: $(basename "$json_file")" >&2
        continue
    fi

    # Append to merged array
    merged=$(echo "$merged" | jq --argjson obj "$local_obj" '. + [$obj]')
done

# Output based on format
if [ "$FORMAT" = "prompt" ]; then
    echo "## PRIOR_BATCH_DISCOVERIES"
    echo ""
    count=$(echo "$merged" | jq 'length')
    if [ "$count" -eq 0 ]; then
        echo "None."
    else
        echo "$merged" | jq -r '.[] | "- **[\(.type)]** (\(.task_id)): \(.summary) — files: \(.affected_files | join(", "))"'
    fi
else
    echo "$merged" | jq -c '.'
fi
