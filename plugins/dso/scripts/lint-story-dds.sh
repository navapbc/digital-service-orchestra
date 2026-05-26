#!/usr/bin/env bash
# lint-story-dds.sh — Advisory lint for a story ticket's Done Definitions.
#
# Reads the story's `## Done Definitions` section and warns to stderr when no
# DD line contains a behavioral verb from the allowlist. ADVISORY ONLY:
# always exits 0 so it cannot block preplanning or any other workflow.
#
# Usage:
#   bash "${_PLUGIN_GIT_PATH}/scripts/lint-story-dds.sh" <story-id>
#   bash "${_PLUGIN_GIT_PATH}/scripts/lint-story-dds.sh" --file <path-to-fixture-markdown>
#
# Environment:
#   DSO_TICKET_CLI           — override ticket CLI path (default: .claude/scripts/dso)
#   LINT_DD_VERB_ALLOWLIST   — pipe-separated regex; default matches behavioral verbs.
#
# Default allowlist:
#   produces|writes|appears|emits|outputs|creates|removes|drops|
#   increases|decreases|file.*exists|file.*content|returns.*shape|
#   state.*change

set -uo pipefail

DEFAULT_VERBS='produces|writes|appears|emits|outputs|creates|removes|drops|increases|decreases|file.*exists|file.*content|returns.*shape|state.*change'
VERBS="${LINT_DD_VERB_ALLOWLIST:-$DEFAULT_VERBS}"
TICKET_CLI="${DSO_TICKET_CLI:-$(git rev-parse --show-toplevel 2>/dev/null)/.claude/scripts/dso}"

if [[ $# -lt 1 ]]; then
    echo "usage: lint-story-dds.sh <story-id> | --file <path>" >&2
    exit 0
fi

# Load description text
if [[ "$1" == "--file" ]]; then
    [[ -f "${2:-}" ]] || { echo "lint-story-dds: file not found: ${2:-}" >&2; exit 0; }
    DESC=$(cat "$2")
    STORY_ID="(fixture:$2)"
else
    STORY_ID="$1"
    if [[ ! -x "$TICKET_CLI" ]]; then
        echo "lint-story-dds: ticket CLI not found at $TICKET_CLI" >&2
        exit 0
    fi
    SHOW_JSON=$("$TICKET_CLI" ticket show "$STORY_ID" 2>/dev/null) || {
        echo "lint-story-dds: ticket show $STORY_ID failed" >&2
        exit 0
    }
    DESC=$(printf '%s' "$SHOW_JSON" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('description','') or '')
except Exception:
    pass
" 2>/dev/null)
fi

# Extract ## Done Definitions section (until next ## or EOF)
DD_BLOCK=$(printf '%s\n' "$DESC" | awk '
    BEGIN { inblk = 0 }
    /^## Done Definitions[[:space:]]*$/ { inblk = 1; next }
    /^## / { if (inblk) { exit } }
    { if (inblk) print }
')

if [[ -z "$DD_BLOCK" ]]; then
    # No DD section at all — advisory note, do not warn
    echo "lint-story-dds: story $STORY_ID has no '## Done Definitions' section (advisory)" >&2
    exit 0
fi

# Pull DD lines (bullets only)
DD_LINES=$(printf '%s\n' "$DD_BLOCK" | grep -E '^[[:space:]]*[-*]' || true)
if [[ -z "$DD_LINES" ]]; then
    echo "lint-story-dds: story $STORY_ID has '## Done Definitions' section but no bullet lines (advisory)" >&2
    exit 0
fi

# Check each DD line for a behavioral verb
MATCH_COUNT=$(printf '%s\n' "$DD_LINES" | grep -iEc "$VERBS" || true)

if [[ "$MATCH_COUNT" -eq 0 ]]; then
    echo "lint-story-dds: WARNING — story $STORY_ID Done Definitions contain no behavioral verbs from the allowlist." >&2
    echo "lint-story-dds:   Allowlist: $VERBS" >&2
    echo "lint-story-dds:   This is advisory only — pairs every DD with an observable behavior to improve verifiability." >&2
fi

exit 0
