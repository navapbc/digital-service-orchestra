#!/usr/bin/env bash
# plugins/dso/scripts/figma-url-store.sh
# Extract a Figma file key from a URL and store it on a ticket as a comment.
#
# Usage: figma-url-store.sh <ticket-id> <figma-url>
#
# Steps:
#   1. Parse ticket-id and Figma URL arguments
#   2. Extract file key via figma-url-parse.sh
#   3. Store "figma_file_key: <key>" as a ticket comment
#   4. Print success message
#
# The stored comment is later read by figma-resync.py to locate the file for re-sync.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"

TICKET_ID="${1:-}"
FIGMA_URL="${2:-}"

if [[ -z "$TICKET_ID" || -z "$FIGMA_URL" ]]; then
    printf 'Usage: %s <ticket-id> <figma-url>\n' "$(basename "$0")" >&2
    printf 'Example: %s 5250-e85b https://www.figma.com/design/abc123/My-Design\n' "$(basename "$0")" >&2
    exit 1
fi

# ── Extract file key ──────────────────────────────────────────────────────────
URL_PARSE="$SCRIPT_DIR/figma-url-parse.sh"
if [[ ! -f "$URL_PARSE" ]]; then
    printf 'Error: figma-url-parse.sh not found at %s\n' "$URL_PARSE" >&2
    exit 1
fi

FILE_KEY=$(bash "$URL_PARSE" "$FIGMA_URL")
if [[ -z "$FILE_KEY" ]]; then
    printf 'Error: could not extract file key from URL: %s\n' "$FIGMA_URL" >&2
    exit 1
fi

# ── Store on ticket ───────────────────────────────────────────────────────────
_run_ticket() {
    if [ -n "${TICKET_CMD:-}" ]; then
        "$TICKET_CMD" "$@"
    else
        "$PROJECT_ROOT/.claude/scripts/dso" ticket "$@"
    fi
}

_run_ticket comment "$TICKET_ID" "figma_file_key: $FILE_KEY"

printf 'Figma file key stored on ticket %s: %s\n' "$TICKET_ID" "$FILE_KEY"
