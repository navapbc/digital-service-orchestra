#!/usr/bin/env bash
# scripts/implementation-plan/resolve-feature-flag-approval.sh
#
# Two-hop tag-lookup helper for feature-flag approval status.
#
# CHECKPOINT: Implements the FEATURE_FLAGS_APPROVED marker for implementation-plan
# Step 1. This helper is called by the orchestrator (NOT the LLM task-decomposer)
# and has full ticket CLI access.
#
# Argv contract:
#   resolve-feature-flag-approval.sh <story_id>
#
#   story_id — the story ticket ID to evaluate (required)
#
# Lookup algorithm:
#   1. Run `dso ticket show <story_id>` → parse tags and parent_id
#   2. If story tags contain TAG_FEATURE_FLAGS_APPROVED → approved, source=story
#   3. If parent_id is non-null, run `dso ticket show <parent_id>` → parse tags
#   4. If parent tags contain TAG_FEATURE_FLAGS_APPROVED → approved, source=parent
#   5. Otherwise → prohibited, source=none, non-empty reason
#
# Safe defaults (all exit 0, NEVER non-zero — a non-zero exit halts Step 1 for all stories):
#   - Story ticket show fails → prohibited, reason=lookup-failure
#   - Story has no parent (null/empty parent_id) → prohibited, reason=no-parent
#   - Parent ticket show fails → prohibited, reason=parent-lookup-failure
#   - Neither story nor parent has the tag → prohibited, reason=tag-absent-on-story-and-parent
#
# Output:
#   A single-line JSON object on stdout:
#   {"feature-flags":"approved|prohibited","reason":"<non-empty string>","source":"story|parent|none"}
#
# Configuration:
#   TAG_FEATURE_FLAGS_APPROVED — sourced from planning-tags.conf

set -uo pipefail

# ── Locate plugin root relative to this script ────────────────────────────────
# Script lives at: <plugin_root>/scripts/implementation-plan/resolve-feature-flag-approval.sh
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${_SCRIPT_DIR}/../.." && pwd)}"

# ── Source the tag constants ──────────────────────────────────────────────────
# shellcheck source=../../skills/shared/constants/planning-tags.conf
# CHECKPOINT: source planning-tags.conf to get TAG_FEATURE_FLAGS_APPROVED
source "${_PLUGIN_ROOT}/skills/shared/constants/planning-tags.conf"

# ── Parse arguments ───────────────────────────────────────────────────────────
STORY_ID="${1:-}"

# ── Emit JSON helper ──────────────────────────────────────────────────────────
_emit_json() {
    local verdict="$1"
    local reason="$2"
    local source="$3"
    # Escape double-quotes for JSON safety
    reason="${reason//\"/\\\"}"
    printf '{"feature-flags":"%s","reason":"%s","source":"%s"}\n' \
        "$verdict" "$reason" "$source"
}

# ── Resolve the dso CLI path ──────────────────────────────────────────────────
# When invoked from a sandbox (tests), the sandbox provides .claude/scripts/dso
# relative to cwd. Otherwise resolve via git toplevel.
_get_dso_cli() {
    if [[ -x ".claude/scripts/dso" ]]; then
        echo ".claude/scripts/dso"
    else
        local _repo_root
        _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
        echo "${_repo_root}/.claude/scripts/dso"
    fi
}

# ── Validate arguments ────────────────────────────────────────────────────────
if [[ -z "$STORY_ID" ]]; then
    _emit_json "prohibited" "no-story-id-provided" "none"
    exit 0
fi

# ── Resolve dso CLI ───────────────────────────────────────────────────────────
DSO_CLI="$(_get_dso_cli)"

# ── Step 1: Fetch story ticket ────────────────────────────────────────────────
# CHECKPOINT: story lookup — safe-default on any failure
story_json=""
if ! story_json=$("$DSO_CLI" ticket show "$STORY_ID" 2>/dev/null); then
    _emit_json "prohibited" "story-lookup-failed-for-${STORY_ID}" "none"
    exit 0
fi

# Validate we got non-empty output that looks like JSON
if [[ -z "$story_json" ]] || ! echo "$story_json" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
    _emit_json "prohibited" "story-output-unparseable-for-${STORY_ID}" "none"
    exit 0
fi

# ── Step 2: Check story tags ──────────────────────────────────────────────────
# Parse story tags array — check for TAG_FEATURE_FLAGS_APPROVED
story_has_tag=$(echo "$story_json" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
tags = d.get('tags', []) or []
flag = '${TAG_FEATURE_FLAGS_APPROVED}'
print('yes' if flag in tags else 'no')
" 2>/dev/null || echo "no")

if [[ "$story_has_tag" == "yes" ]]; then
    _emit_json "approved" "tag-found-on-story" "story"
    exit 0
fi

# ── Step 3: Extract parent_id from story ─────────────────────────────────────
# CHECKPOINT: parse parent_id field; null/empty means orphan story → safe-default
parent_id=$(echo "$story_json" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
pid = d.get('parent_id')
print(pid if pid else '')
" 2>/dev/null || echo "")

if [[ -z "$parent_id" ]]; then
    _emit_json "prohibited" "no-parent-on-story-${STORY_ID}" "none"
    exit 0
fi

# ── Step 4: Fetch parent (epic) ticket ───────────────────────────────────────
# CHECKPOINT: parent lookup — safe-default on failure (handles jira-* sync lag)
parent_json=""
if ! parent_json=$("$DSO_CLI" ticket show "$parent_id" 2>/dev/null); then
    _emit_json "prohibited" "parent-lookup-failed-for-${parent_id}" "none"
    exit 0
fi

if [[ -z "$parent_json" ]] || ! echo "$parent_json" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
    _emit_json "prohibited" "parent-output-unparseable-for-${parent_id}" "none"
    exit 0
fi

# ── Step 5: Check parent tags ─────────────────────────────────────────────────
parent_has_tag=$(echo "$parent_json" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
tags = d.get('tags', []) or []
flag = '${TAG_FEATURE_FLAGS_APPROVED}'
print('yes' if flag in tags else 'no')
" 2>/dev/null || echo "no")

if [[ "$parent_has_tag" == "yes" ]]; then
    _emit_json "approved" "tag-found-on-parent-${parent_id}" "parent"
    exit 0
fi

# ── Step 6: Neither story nor parent has the tag ──────────────────────────────
_emit_json "prohibited" "tag-absent-on-story-and-parent-${parent_id}" "none"
exit 0
