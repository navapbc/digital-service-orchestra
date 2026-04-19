#!/usr/bin/env bash
# design-approve.sh
# Approve a Figma design revision for a story.
#
# Usage: design-approve.sh <story-id>
#
# Steps:
#   1. Parse story ID argument
#   2. Source figma-tags.conf for tag constants
#   3. Get story data via ticket show
#   4. Find design UUID from story comments or use story-id as design dir
#   5. Validate designs/{uuid}/figma-revision.png exists and is non-empty
#   6. Verify story has TAG_AWAITING_IMPORT
#   7. Add TAG_APPROVED and remove TAG_AWAITING_IMPORT via ticket tag/untag
#   8. Print success message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"

# ── Source figma tag constants ────────────────────────────────────────────────
FIGMA_TAGS_CONF="$CLAUDE_PLUGIN_ROOT/skills/shared/constants/figma-tags.conf"
if [ ! -f "$FIGMA_TAGS_CONF" ]; then
    echo "Error: figma-tags.conf not found at $FIGMA_TAGS_CONF" >&2
    exit 1
fi
# shellcheck source=${CLAUDE_PLUGIN_ROOT}/skills/shared/constants/figma-tags.conf
source "$FIGMA_TAGS_CONF"

# ── Resolve project root and ticket CLI ──────────────────────────────────────
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"

# TICKET_CMD may be:
#   - A single executable path (e.g., tests set it to a stub at "$tmpdir/ticket")
#   - Unset (use the default dso ticket shim)
# _run_ticket <subcommand> [args...] handles both cases.
_run_ticket() {
    if [ -n "${TICKET_CMD:-}" ]; then
        "$TICKET_CMD" "$@"
    else
        "$PROJECT_ROOT/.claude/scripts/dso" ticket "$@"
    fi
}

# ── Parse arguments ──────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Usage: design-approve.sh <story-id>" >&2
    exit 1
fi

story_id="$1"

# ── Get story data via ticket show ────────────────────────────────────────────
story_json=$(_run_ticket show "$story_id" 2>/dev/null) || {
    echo "Error: failed to get story data for '$story_id'" >&2
    exit 1
}

# ── Find design UUID from story comments (look for Design Manifest/Brief pattern) ──
# Fall back to using the story_id itself as the design directory name
design_uuid=$(python3 -c "
import json, sys, re
data = json.loads(sys.argv[1])
for comment in data.get('comments', []):
    body = comment.get('body', '') if isinstance(comment, dict) else str(comment)
    match = re.search(r'designs/([^/\s]+)/', body)
    if match:
        print(match.group(1))
        break
" "$story_json" 2>/dev/null) || true

if [ -z "$design_uuid" ]; then
    # No design UUID found in comments — use story_id as design directory
    design_uuid="$story_id"
fi

# ── Validate designs/{uuid}/figma-revision.png exists and is non-empty ────────
png_path="$PROJECT_ROOT/designs/$design_uuid/figma-revision.png"

if [ ! -f "$png_path" ]; then
    echo "Error: Export PNG from Figma to designs/${design_uuid}/figma-revision.png" >&2
    exit 1
fi

if [ ! -s "$png_path" ]; then
    echo "Error: figma-revision.png is empty or invalid — export a valid PNG from Figma to designs/${design_uuid}/figma-revision.png" >&2
    exit 1
fi

# ── Read current tags from ticket JSON ───────────────────────────────────────
current_tags=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
tags = data.get('tags', [])
print('\n'.join(tags))
" "$story_json")

# ── Validate story has TAG_AWAITING_IMPORT ────────────────────────────────────
if ! echo "$current_tags" | grep -qxF "$TAG_AWAITING_IMPORT"; then
    echo "Error: story '$story_id' is not in awaiting_import state (missing tag: $TAG_AWAITING_IMPORT)" >&2
    exit 1
fi

# ── Update tags via ticket tag/untag subcommands ──────────────────────────────
_run_ticket tag "$story_id" "$TAG_APPROVED" || {
    echo "Error: failed to add tag '$TAG_APPROVED' for story '$story_id'" >&2
    exit 1
}
_run_ticket untag "$story_id" "$TAG_AWAITING_IMPORT" || {
    echo "Error: failed to remove tag '$TAG_AWAITING_IMPORT' for story '$story_id'" >&2
    exit 1
}

# ── Success ───────────────────────────────────────────────────────────────────
echo "Design approved for story '$story_id'."
