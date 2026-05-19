#!/usr/bin/env bash
# classify-bug-at-closure.sh
#
# Classifies a bug ticket at closure time using the bug-classification registry.
#
# Usage:
#   classify-bug-at-closure.sh <ticket-id> <reason-prefix>
#
# Arguments:
#   ticket-id     — the bug ticket ID to classify
#   reason-prefix — the first part of the --reason string (e.g. "Fixed:" or "Escalated to user:")
#
# Environment overrides (for testability):
#   TICKET_CMD         — override ticket CLI (default: $SCRIPT_DIR/ticket)
#   CLASSIFIER_OUTPUT  — if set, use as classifier agent output (bypasses real agent dispatch)
#   REGISTRY_FILE      — override registry JSON path
#
# Exit codes:
#   Always exits 0 — failures are handled gracefully internally.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Arguments ─────────────────────────────────────────────────────────────────
TICKET_ID="${1:-}"
REASON_PREFIX="${2:-}"

if [[ -z "$TICKET_ID" || -z "$REASON_PREFIX" ]]; then
    printf "Usage: %s <ticket-id> <reason-prefix>\n" "$(basename "$0")" >&2
    exit 0
fi

# ── Environment defaults ──────────────────────────────────────────────────────
TICKET_CMD="${TICKET_CMD:-"$SCRIPT_DIR/ticket"}"
REGISTRY_FILE="${REGISTRY_FILE:-"$SCRIPT_DIR/../docs/bug-classification-registry.json"}"

# ── Skip condition ────────────────────────────────────────────────────────────
# Only classify tickets closed with "Fixed:" prefix.
if [[ "$REASON_PREFIX" != Fixed:* ]]; then
    exit 0
fi

# ── Load slug set from registry ───────────────────────────────────────────────
SLUG_SET=""
if [[ -f "$REGISTRY_FILE" ]]; then
    SLUG_SET=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
slugs = [e['slug'] for e in data.get('entries', [])]
print('\n'.join(slugs))
" "$REGISTRY_FILE" 2>/dev/null || true)
fi

# ── Get classifier output ─────────────────────────────────────────────────────
# Architecture: bug-classifier-haiku agent dispatch is orchestrator-side.
# The LLM orchestrator reads this script, dispatches the agent via the Agent
# tool, and injects the output into CLASSIFIER_OUTPUT before calling this helper.
# This script centralizes output validation, tagging, retry, and
# comment-on-failure so each calling SKILL.md doesn't re-implement them.
# In test mode CLASSIFIER_OUTPUT is set directly by the test fixture.
RAW_OUTPUT="${CLASSIFIER_OUTPUT:-}"

# Trim whitespace from output
TRIMMED_OUTPUT="$(printf '%s' "$RAW_OUTPUT" | tr -d '[:space:]')"

# ── Validate output against slug set ─────────────────────────────────────────
# Valid if trimmed output is in slug_set OR is "uncategorized"
is_valid_slug() {
    local slug="$1"
    [[ -z "$slug" ]] && return 1
    [[ "$slug" == "uncategorized" ]] && return 0
    while IFS= read -r line; do
        [[ -n "$line" && "$line" == "$slug" ]] && return 0
    done <<< "$SLUG_SET"
    return 1
}

# ── Tag write with retry ──────────────────────────────────────────────────────
# Attempts tag write; retries once on failure; comments on ticket if second
# attempt also fails.
_apply_tag() {
    local tid="$1" tag="$2"
    if "$TICKET_CMD" tag "$tid" "$tag" 2>/dev/null; then
        return 0
    fi
    # Retry once
    if "$TICKET_CMD" tag "$tid" "$tag" 2>/dev/null; then
        return 0
    fi
    # Both attempts failed — leave a comment so the failure is visible
    "$TICKET_CMD" comment "$tid" "CLASSIFIER_WARN: tag write failed after retry for $tag" 2>/dev/null || true
    return 1
}

if is_valid_slug "$TRIMMED_OUTPUT"; then
    # Valid slug — apply the tag (with retry)
    _apply_tag "$TICKET_ID" "bug-type-$TRIMMED_OUTPUT" || true
else
    # Schema failure — write both fallback tags (each with retry)
    _apply_tag "$TICKET_ID" "bug-type-uncategorized" || true
    _apply_tag "$TICKET_ID" "bug-type-classifier-failed-schema" || true
fi

exit 0
