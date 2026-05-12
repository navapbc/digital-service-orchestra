#!/usr/bin/env bash
# detect-session-leakage.sh — detects non-merge commits that bypassed check-session-merge-only.sh
# Called from SKILL.md Phase F after story branch merges.
# Scans non-merge commits on the session branch (between merge-base with main and HEAD)
# and routes each commit using a 5-case matrix:
#   Case 1: DSO-Story trailer + open story → merge commit to story/<epic>/<story-id>
#   Case 2: DSO-Task/DSO-Bug trailer, no DSO-Story → merge to story/orphan-<session>
#   Case 3: No DSO-* trailers → exit 1 + "manual attribution" + SHA on stderr
#   Case 4: DSO-Story trailer + closed story → exit 1 + --force-route-to hint + candidates
#   Case 5: Merge conflict → abort + exit 1 + SHA + conflicting paths on stderr
#
# Usage: detect-session-leakage.sh [--force-route-to=<story-id>]

set -euo pipefail

DSO_TICKET_CLI="${DSO_TICKET_CLI:-.claude/scripts/dso}"
DSO_MAIN_BRANCH="${DSO_MAIN_BRANCH:-main}"

# ── Parse arguments ───────────────────────────────────────────────────────────
FORCE_ROUTE_TO=""
_args=("$@")
_i=0
while [[ $_i -lt ${#_args[@]} ]]; do
    case "${_args[$_i]}" in
        --force-route-to=*)
            FORCE_ROUTE_TO="${_args[$_i]#--force-route-to=}"
            ;;
        --force-route-to)
            _i=$(( _i + 1 ))
            FORCE_ROUTE_TO="${_args[$_i]:-}"
            ;;
    esac
    _i=$(( _i + 1 ))
done

# ── Compute merge-base with main ──────────────────────────────────────────────
MERGE_BASE=$(git merge-base HEAD "$DSO_MAIN_BRANCH" 2>/dev/null) || {
    printf "ERROR: could not compute merge-base with %s\n" "$DSO_MAIN_BRANCH" >&2
    exit 1
}

SESSION_BRANCH=$(git rev-parse --abbrev-ref HEAD)
SESSION_HEAD=$(git rev-parse HEAD)

# ── Load all stories from ticket CLI (one call, reused for all commits) ───────
STORIES_JSON=$("$DSO_TICKET_CLI" ticket list --type=story 2>/dev/null) || STORIES_JSON="[]"
export STORIES_JSON

# ── Helper: look up story by title in STORIES_JSON (exported) ─────────────────
# Prints: <ticket_id> TAB <status> TAB <parent_id>  or exits 1 if not found
lookup_story_by_title() {
    local title="$1"
    python3 -c "
import json, sys, os
title = sys.argv[1]
stories_json = os.environ.get('STORIES_JSON', '[]')
tickets = json.loads(stories_json)
for t in tickets:
    if t.get('title', '') == title:
        print('{}\t{}\t{}'.format(t.get('ticket_id',''), t.get('status',''), t.get('parent_id','')))
        sys.exit(0)
sys.exit(1)
" "$title"
}

# ── Helper: look up story epic by ticket_id in STORIES_JSON (exported) ────────
# Prints the parent_id or exits 1 if not found
lookup_epic_by_story_id() {
    local story_id="$1"
    python3 -c "
import json, sys, os
story_id = sys.argv[1]
stories_json = os.environ.get('STORIES_JSON', '[]')
tickets = json.loads(stories_json)
for t in tickets:
    if t.get('ticket_id', '') == story_id:
        print(t.get('parent_id', ''))
        sys.exit(0)
sys.exit(1)
" "$story_id"
}

# ── Helper: list open story ids from STORIES_JSON (exported) ─────────────────
list_open_story_ids() {
    python3 -c "
import json, sys, os
stories_json = os.environ.get('STORIES_JSON', '[]')
tickets = json.loads(stories_json)
open_ids = [t['ticket_id'] for t in tickets if t.get('status') == 'open']
print(' '.join(open_ids))
"
}

# ── Helper: merge session HEAD into a target branch, preserving SHAs when possible
# Returns 0 on success, 1 on conflict (also aborts the merge and restores branch).
# Usage: merge_into_branch <target-branch> <sha-to-merge>
# On conflict: prints conflicting file paths to stderr and returns 1.
merge_into_branch() {
    local target_branch="$1"
    local sha="$2"

    git checkout -q "$target_branch"
    # Use --ff-only first — preserves the original SHA when the branch is behind
    if git merge --ff-only "$sha" >/dev/null 2>&1; then
        git checkout -q "$SESSION_BRANCH"
        return 0
    fi
    # Fall back to a regular merge (will create a merge commit but handles non-FF cases)
    if git merge --no-edit "$sha" >/dev/null 2>&1; then
        git checkout -q "$SESSION_BRANCH"
        return 0
    fi
    # Conflict: collect paths, abort, restore
    local conflict_files
    conflict_files=$(git ls-files -u 2>/dev/null | awk -F'\t' '{print $2}' | sort -u | tr '\n' ' ' || true)
    git merge --abort 2>/dev/null || true
    git checkout -q "$SESSION_BRANCH"
    printf "%s" "$conflict_files"
    return 1
}

# ── Collect non-merge commits since merge-base ────────────────────────────────
_raw_commits=$(git log --no-merges --format="%H" "${MERGE_BASE}..HEAD" 2>/dev/null)

if [[ -z "$_raw_commits" ]]; then
    exit 0
fi

# Reverse to oldest-first (compatible with both GNU/BSD awk)
COMMIT_LIST=$(printf '%s\n' "$_raw_commits" | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--) print lines[i]}')

OVERALL_EXIT=0

while IFS= read -r SHA; do
    [[ -z "$SHA" ]] && continue

    COMMIT_MSG=$(git log -1 --format="%B" "$SHA")

    # Extract DSO trailers
    STORY_TRAILER=$(printf '%s\n' "$COMMIT_MSG" | grep -m1 '^DSO-Story: ' | sed 's/^DSO-Story: //' | tr -d '\r' || true)
    TASK_TRAILER=$(printf '%s\n' "$COMMIT_MSG" | grep -m1 '^DSO-Task: ' || true)
    BUG_TRAILER=$(printf '%s\n' "$COMMIT_MSG" | grep -m1 '^DSO-Bug: ' || true)

    HAS_STORY="${STORY_TRAILER:+yes}"
    HAS_TASK_OR_BUG=""
    [[ -n "$TASK_TRAILER" || -n "$BUG_TRAILER" ]] && HAS_TASK_OR_BUG="yes"

    # ── Case 3: No DSO trailers at all ────────────────────────────────────────
    if [[ -z "$HAS_STORY" && -z "$HAS_TASK_OR_BUG" ]]; then
        printf "LEAKAGE: unattributed commit %s — no DSO trailers, manual attribution required\n" "$SHA" >&2
        OVERALL_EXIT=1
        continue
    fi

    # ── Case 2: DSO-Task/Bug present but no DSO-Story → orphan branch ─────────
    if [[ -z "$HAS_STORY" && -n "$HAS_TASK_OR_BUG" ]]; then
        ORPHAN_BRANCH="story/orphan-${SESSION_BRANCH}"
        # Create orphan branch from merge-base if it doesn't exist
        if ! git rev-parse --verify "$ORPHAN_BRANCH" >/dev/null 2>&1; then
            git branch "$ORPHAN_BRANCH" "$MERGE_BASE" >/dev/null 2>&1
        fi
        CONFLICT_FILES=$(merge_into_branch "$ORPHAN_BRANCH" "$SHA") || {
            printf "LEAKAGE: conflict merging orphan commit %s to %s — conflicting: %s\n" "$SHA" "$ORPHAN_BRANCH" "$CONFLICT_FILES" >&2
            OVERALL_EXIT=1
        }
        continue
    fi

    # ── Cases 1 and 4: DSO-Story trailer present ───────────────────────────────
    if [[ -n "$HAS_STORY" ]]; then
        # Look up story by title
        LOOKUP_RESULT=$(lookup_story_by_title "$STORY_TRAILER" 2>/dev/null) || LOOKUP_RESULT=""

        if [[ -z "$LOOKUP_RESULT" ]]; then
            # Story not found in ticket system — treat as unattributed
            printf "LEAKAGE: unattributed commit %s — DSO-Story '%s' not found in ticket system, manual attribution required\n" "$SHA" "$STORY_TRAILER" >&2
            OVERALL_EXIT=1
            continue
        fi

        STORY_ID=$(printf '%s\n' "$LOOKUP_RESULT" | cut -f1)
        STORY_STATUS=$(printf '%s\n' "$LOOKUP_RESULT" | cut -f2)
        STORY_EPIC=$(printf '%s\n' "$LOOKUP_RESULT" | cut -f3)

        # ── Case 4: Closed/archived story ─────────────────────────────────────
        if [[ "$STORY_STATUS" == "closed" || "$STORY_STATUS" == "archived" ]]; then
            if [[ -n "$FORCE_ROUTE_TO" ]]; then
                # Look up the force-route story's epic by ticket_id
                FORCE_EPIC=$(lookup_epic_by_story_id "$FORCE_ROUTE_TO" 2>/dev/null) || FORCE_EPIC=""

                TARGET_BRANCH="story/${FORCE_EPIC}/${FORCE_ROUTE_TO}"
                if ! git rev-parse --verify "$TARGET_BRANCH" >/dev/null 2>&1; then
                    printf "LEAKAGE: branch-not-found %s for commit %s — branch %s does not exist\n" "$FORCE_ROUTE_TO" "$SHA" "$TARGET_BRANCH" >&2
                    OVERALL_EXIT=1
                    continue
                fi

                CONFLICT_FILES=$(merge_into_branch "$TARGET_BRANCH" "$SHA") || {
                    printf "LEAKAGE: conflict merging commit %s to %s — conflicting: %s\n" "$SHA" "$TARGET_BRANCH" "$CONFLICT_FILES" >&2
                    OVERALL_EXIT=1
                    continue
                }
                # Add comment on re-routed story
                "$DSO_TICKET_CLI" ticket comment "$FORCE_ROUTE_TO" "Re-attributed commit ${SHA} from closed story." 2>/dev/null || true
            else
                # No --force-route-to: emit hint with open candidates
                OPEN_CANDIDATES=$(list_open_story_ids 2>/dev/null) || OPEN_CANDIDATES=""
                printf "LEAKAGE: closed-story commit %s — story is closed, use --force-route-to <id> to re-attribute\n  candidates: %s\n" "$SHA" "$OPEN_CANDIDATES" >&2
                OVERALL_EXIT=1
            fi
            continue
        fi

        # ── Case 1: Open story → merge to story/<epic>/<story-id> ────────
        TARGET_BRANCH="story/${STORY_EPIC}/${STORY_ID}"

        CONFLICT_FILES=$(merge_into_branch "$TARGET_BRANCH" "$SHA") || {
            printf "LEAKAGE: conflict merging commit %s to %s — conflicting: %s SHA: %s\n" "$SHA" "$TARGET_BRANCH" "$CONFLICT_FILES" "$SHA" >&2
            OVERALL_EXIT=1
        }
        continue
    fi

done <<< "$COMMIT_LIST"

exit "$OVERALL_EXIT"
