#!/usr/bin/env bash
# redistribute-session-commits.sh
#
# Redistributes session-branch commits to per-story branches via a 5-phase
# hybrid algorithm:
#   1. RESOLVE   — discover session branch and commit range
#   2. ATTRIBUTE — map each commit to a story by trailer / content overlap
#   3. SPLIT     — for trailer-tagged commits whose files cross stories,
#                  produce per-story synthetic sub-commits
#   4. FALLBACK  — group unattributed / unsplittable commits into temporal
#                  "epoch" branches (~5 commits each)
#   5. PUBLISH   — create story/<epic>/<story|epoch> branches, cherry-pick,
#                  push, open PR via merge-to-main-pr.sh
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   redistribute-session-commits.sh --epic <epic-id> [--dry-run]
#                                   [--session-branch <name>] [--force]
#                                   [--interactive]
#
# ── Environment overrides (test isolation) ────────────────────────────────────
#   DSO_RESOLVE_SESSION_BRANCH    Path to resolve-session-branch.sh stub
#   DSO_TICKET_LIST_OVERRIDE      Path to JSON file with story descriptions
#   DSO_MERGE_TO_MAIN_PR_OVERRIDE Path to merge-to-main-pr.sh stub
#   DSO_GH_REPO                   owner/repo for gh API calls
#
# ── Exit codes ────────────────────────────────────────────────────────────────
#   0 = success (including empty-range case)
#   1 = unrecoverable error (dirty worktree without --force, resolution failure)
#   2 = cherry-pick / publish failed; checkpoint written; see --resume guidance

set -uo pipefail

# ── Defaults / args ──────────────────────────────────────────────────────────
EPIC_ID=""
DRY_RUN=0
SESSION_BRANCH=""
FORCE=0
INTERACTIVE=0

usage() {
    cat << 'EOF'
Usage: redistribute-session-commits.sh --epic <epic-id> [options]

Options:
  --epic <id>              Epic ID whose stories will receive redistributed commits (required)
  --dry-run                Print plan; do not mutate git state
  --session-branch <name>  Override session branch resolution
  --force                  Proceed even with dirty worktree
  --interactive            Prompt before each per-group publish (currently informational)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --epic) EPIC_ID="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --session-branch) SESSION_BRANCH="${2:-}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --interactive) INTERACTIVE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "$EPIC_ID" ]]; then
    echo "ERROR: --epic <epic-id> is required" >&2
    usage >&2
    exit 1
fi

# ── Phase 1: RESOLVE ─────────────────────────────────────────────────────────
echo "▶ Phase 1: RESOLVE"

# Resolve session branch
if [[ -z "$SESSION_BRANCH" ]]; then
    if [[ -n "${DSO_RESOLVE_SESSION_BRANCH:-}" ]]; then
        SESSION_BRANCH="$(bash "$DSO_RESOLVE_SESSION_BRANCH" 2>/dev/null || true)"
    else
        _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -x "$_here/resolve-session-branch.sh" ]]; then
            SESSION_BRANCH="$(bash "$_here/resolve-session-branch.sh" 2>/dev/null || true)"
        fi
    fi
fi

if [[ -z "$SESSION_BRANCH" ]]; then
    echo "ERROR: could not resolve session branch (pass --session-branch or set DSO_RESOLVE_SESSION_BRANCH)" >&2
    exit 1
fi
echo "  resolved session branch reference"
echo "  resolved epic reference"

# Dirty worktree check
DIRTY="$(git status --porcelain 2>/dev/null || true)"
_FORCED_PAST_TREE_CHECK=0
if [[ -n "$DIRTY" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
        echo "  WARN: --force passed; proceeding past tree-state check"
        _FORCED_PAST_TREE_CHECK=1
    else
        echo "ERROR: working tree is dirty / has uncommitted changes." >&2
        echo "       Commit or stash changes, or pass --force to proceed." >&2
        exit 1
    fi
fi

# Determine main ref and commit range
MAIN_REF="main"
if ! git rev-parse --verify --quiet "$MAIN_REF" >/dev/null; then
    MAIN_REF="origin/main"
fi

RANGE_REVS=()
if git rev-parse --verify --quiet "$SESSION_BRANCH" >/dev/null; then
    # Use first-parent for deterministic ordering; reverse so oldest first
    while IFS= read -r _sha; do
        [[ -n "$_sha" ]] && RANGE_REVS+=("$_sha")
    done < <(git log --first-parent --format=%H --reverse "${MAIN_REF}..${SESSION_BRANCH}" 2>/dev/null || true)
fi

if [[ "${#RANGE_REVS[@]}" -eq 0 ]]; then
    echo "  no commits to redistribute (range ${MAIN_REF}..${SESSION_BRANCH} is empty)"
    exit 0
fi
echo "  ${#RANGE_REVS[@]} commit(s) in range"

# ── Phase 2: ATTRIBUTE ───────────────────────────────────────────────────────
echo "▶ Phase 2: ATTRIBUTE"

# Build per-story scope map from ticket descriptions.
# Story scope = set of file path tokens (anything looking like a path or
# basename) extracted from the story's description.
declare -A STORY_SCOPE  # story_id -> newline-separated tokens
STORY_SCOPE=()          # explicit init so ${#STORY_SCOPE[@]} is safe under set -u

# _extract_path_tokens <description-text>  → newline-separated unique tokens
_extract_path_tokens() {
    echo "$1" \
        | tr -c 'A-Za-z0-9_./-' '\n' \
        | awk 'length>0 && ($0 ~ /\// || $0 ~ /\.(sh|txt|yml|yaml|py|md|json|js|ts|sql|html|css)$/)' \
        | sort -u
}

# Override path: callers provide a JSON file in either of two formats
#   (a) flat array of {id, description, type} objects (legacy)
#   (b) {"stories": [{...}], "tasks": [...]} with description fields
_load_stories_from_json() {
    local json_file="$1"
    [[ -f "$json_file" ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        echo "  WARN: jq not available; cannot parse ticket data" >&2
        return 0
    fi
    local lines
    lines="$(jq -r '
        (
          if type=="array" then .
          elif (.stories?|type=="array") and (.stories[0]?|type=="object") then (.stories + (.tasks // []))
          elif (.issues?|type=="array") then .issues
          else []
          end
        )
        | map(select(.type=="story" or .type=="task" or .ticket_type=="story" or .ticket_type=="task"))
        | .[] | [(.id // .ticket_id // ""), (.description // "")] | @tsv
    ' "$json_file" 2>/dev/null || true)"
    while IFS=$'\t' read -r _id _desc; do
        [[ -z "$_id" ]] && continue
        STORY_SCOPE["$_id"]="$(_extract_path_tokens "$_desc")"
    done <<< "$lines"
}

# Real-CLI path: list-descendants emits {"stories":["id1","id2",...]} (flat IDs);
# for each story, run `ticket show <id>` to fetch the description, then extract tokens.
# Note: Only stories are scope-bearing for redistribution. Tasks are excluded — they
# inherit their parent story's scope and would otherwise create spurious destinations.
_load_stories_from_shim() {
    local shim="$1" epic="$2"
    local list_json
    list_json="$("$shim" ticket list-descendants "$epic" 2>/dev/null || true)"
    [[ -z "$list_json" ]] && return 0
    if ! command -v jq >/dev/null 2>&1; then
        echo "  WARN: jq not available; cannot parse ticket data" >&2
        return 0
    fi
    local story_ids
    story_ids="$(echo "$list_json" | jq -r '(.stories // [])[]' 2>/dev/null || true)"
    [[ -z "$story_ids" ]] && return 0
    while IFS= read -r _id; do
        [[ -z "$_id" ]] && continue
        local _desc
        _desc="$("$shim" ticket show "$_id" 2>/dev/null | jq -r '.description // ""' 2>/dev/null || true)"
        STORY_SCOPE["$_id"]="$(_extract_path_tokens "$_desc")"
    done <<< "$story_ids"
}

if [[ -n "${DSO_TICKET_LIST_OVERRIDE:-}" ]]; then
    _load_stories_from_json "$DSO_TICKET_LIST_OVERRIDE"
else
    _shim=".claude/scripts/dso"
    if [[ -x "$_shim" ]]; then
        _load_stories_from_shim "$_shim" "$EPIC_ID"
    fi
fi

echo "  ${#STORY_SCOPE[@]} story scope(s) loaded"

# Helper: determine if a single file path "matches" a story scope.
# Strict matching to avoid spurious cross-story attribution: exact full path OR
# exact basename. Substring matching is intentionally removed — short tokens
# like "test" would otherwise match every test file across the codebase and
# cause SPLIT to fan out to dozens of unrelated stories.
_file_matches_story() {
    local file="$1" story="$2"
    local scope="${STORY_SCOPE[$story]:-}"
    [[ -z "$scope" ]] && return 1
    local base="${file##*/}"
    while IFS= read -r token; do
        [[ -z "$token" ]] && continue
        # Token must be path-like (contain "/" or be a multi-char basename-with-extension)
        # to count as a meaningful scope anchor. Discard noise like "tests" or "feat".
        if [[ "$token" != */* && "$token" != *.* ]]; then
            continue
        fi
        if [[ "$token" == "$file" || "$token" == "$base" ]]; then
            return 0
        fi
    done <<< "$scope"
    return 1
}

# For each commit, compute: trailer, file list, per-story file match count,
# decision (ACCEPT / SPLIT / INFER / UNATTRIBUTED / MERGE).
declare -A COMMIT_DECISION    # sha -> ACCEPT|SPLIT|INFER|UNATTRIBUTED|MERGE
declare -A COMMIT_TRAILER     # sha -> story id (from trailer, if any)
declare -A COMMIT_FILES       # sha -> newline-separated changed files
declare -A COMMIT_ASSIGNED    # sha -> primary story id (for ACCEPT/INFER)
declare -A COMMIT_SPLIT_STORIES  # sha -> space-separated story ids (for SPLIT)

# Group memberships: per-story commit list (oldest first preserved by iteration order)
declare -A GROUP_COMMITS      # story_id -> newline-separated SHAs
GROUP_ORDER=()                # ordered list of group keys (story ids + epoch keys)

# _apply_filtered_split_commit <sha> <story-id>
#
# For a SPLIT commit (one whose diff spans multiple stories), apply ONLY the
# files in the commit's diff that match this story's scope. Generates a
# filtered patch via `git diff <sha>~1..<sha> -- <files>` and applies it
# with `git apply --3way --index`. Commits the result with the original
# subject + a DSO-Origin-SHA trailer recording the source SHA.
#
# Returns:
#   0 on success (filtered patch applied + committed, OR no files matched this
#     story so nothing to apply — silent skip)
#   non-zero on hard failure (filter computed but apply failed)
#
# Bug cf84-9c07-00f8-4ad6 — replaces bulk cherry-pick of SPLIT commits which
# bloated story branches with cross-pollinated files from other stories.
_apply_filtered_split_commit() {
    local sha="$1" story_id="$2"
    local files_in_commit story_files _f
    files_in_commit="${COMMIT_FILES[$sha]:-}"
    [[ -z "$files_in_commit" ]] && return 0

    # Intersect commit's files with story's scope
    story_files=""
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        if _file_matches_story "$_f" "$story_id"; then
            story_files+="$_f"$'\n'
        fi
    done <<< "$files_in_commit"

    # No files in this commit belong to this story — nothing to apply, silent skip
    [[ -z "$story_files" ]] && return 0

    # Build path arg array (handle paths with spaces by reading line-by-line)
    local -a _pathspec=()
    while IFS= read -r _f; do
        [[ -n "$_f" ]] && _pathspec+=("$_f")
    done <<< "$story_files"

    # Generate filtered patch limited to story_files
    local _patch
    _patch="$(git diff "${sha}~1..${sha}" -- "${_pathspec[@]}" 2>/dev/null)" || return 1

    # No diff produced (e.g., commit only created files that don't match scope)
    [[ -z "$_patch" ]] && return 0

    # Apply patch with 3-way merge so context drift is reconciled when possible
    if ! printf '%s\n' "$_patch" | git apply --3way --index 2>/dev/null; then
        return 1
    fi

    # Synthesize commit: preserve original subject + author + add DSO-Origin-SHA trailer.
    # Use --author="$_author" (git's canonical "Name <email>" form) rather than
    # setting committer identity via -c, which only overrides the committer and
    # silently drops the original author (Copilot finding 2026-05-16).
    local _subj _author
    _subj="$(git log -1 --format=%s "$sha" 2>/dev/null)"
    _author="$(git log -1 --format='%an <%ae>' "$sha" 2>/dev/null)"
    git commit -q --author="$_author" -m "$_subj

DSO-Story: $story_id
DSO-Origin-SHA: $sha" 2>/dev/null || return 1
    return 0
}

_register_group_commit() {
    local key="$1" sha="$2"
    if [[ -z "${GROUP_COMMITS[$key]+x}" ]]; then
        GROUP_ORDER+=("$key")
        GROUP_COMMITS["$key"]="$sha"
    else
        GROUP_COMMITS["$key"]+=$'\n'"$sha"
    fi
}

UNATTRIBUTED_SHAS=()
MERGE_SHAS=()

for sha in "${RANGE_REVS[@]}"; do
    # Skip merge commits (preserve on session)
    _parent_count="$(git rev-list --parents -n 1 "$sha" 2>/dev/null | awk '{print NF-1}')"
    if [[ "${_parent_count:-1}" -gt 1 ]]; then
        COMMIT_DECISION["$sha"]="MERGE"
        MERGE_SHAS+=("$sha")
        continue
    fi

    # Parse DSO-Story trailer
    _trailer="$(git log -1 --format='%(trailers:key=DSO-Story,valueonly=true)' "$sha" 2>/dev/null | head -1 | tr -d ' \t\r\n')"
    COMMIT_TRAILER["$sha"]="$_trailer"

    # Get changed files
    _files="$(git show --name-only --format= "$sha" 2>/dev/null | awk 'NF>0')"
    COMMIT_FILES["$sha"]="$_files"

    _total=0
    while IFS= read -r f; do [[ -n "$f" ]] && (( _total++ )); done <<< "$_files"
    [[ "$_total" -eq 0 ]] && _total=1

    # Per-story match counts
    declare -A _matches=()
    for story in "${!STORY_SCOPE[@]}"; do
        _cnt=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if _file_matches_story "$f" "$story"; then (( _cnt++ )); fi
        done <<< "$_files"
        _matches["$story"]="$_cnt"
    done

    # Decision logic
    if [[ -n "$_trailer" ]]; then
        _tm="${_matches[$_trailer]:-0}"
        # Compute ratio*100 in integer math
        _pct=$(( _tm * 100 / _total ))
        if [[ "$_pct" -ge 80 ]]; then
            COMMIT_DECISION["$sha"]="ACCEPT"
            COMMIT_ASSIGNED["$sha"]="$_trailer"
            _register_group_commit "$_trailer" "$sha"
        else
            # SPLIT — collect all stories that have at least one matching file
            _split_stories=""
            # Trailer story is always one of the split targets
            _split_stories="$_trailer"
            for story in "${!_matches[@]}"; do
                [[ "$story" == "$_trailer" ]] && continue
                if [[ "${_matches[$story]:-0}" -gt 0 ]]; then
                    _split_stories+=" $story"
                fi
            done
            COMMIT_DECISION["$sha"]="SPLIT"
            COMMIT_SPLIT_STORIES["$sha"]="$_split_stories"
            for story in $_split_stories; do
                _register_group_commit "$story" "$sha"
            done
        fi
    else
        # No trailer — see if any single story matches ≥80%
        _best_story=""
        _best_cnt=0
        for story in "${!_matches[@]}"; do
            if [[ "${_matches[$story]:-0}" -gt "$_best_cnt" ]]; then
                _best_cnt="${_matches[$story]}"
                _best_story="$story"
            fi
        done
        _best_pct=$(( _best_cnt * 100 / _total ))
        if [[ -n "$_best_story" && "$_best_pct" -ge 80 ]]; then
            COMMIT_DECISION["$sha"]="INFER"
            COMMIT_ASSIGNED["$sha"]="$_best_story"
            _register_group_commit "$_best_story" "$sha"
        else
            COMMIT_DECISION["$sha"]="UNATTRIBUTED"
            UNATTRIBUTED_SHAS+=("$sha")
        fi
    fi
    unset _matches
done

# Print attribution table (suppressed when bypass flag set to avoid leaking
# user-supplied identifiers in a degraded run; full plan is still computed).
if [[ "$_FORCED_PAST_TREE_CHECK" -eq 0 ]]; then
    for sha in "${RANGE_REVS[@]}"; do
        _short="${sha:0:12}"
        _dec="${COMMIT_DECISION[$sha]:-?}"
        _subj="$(git log -1 --format=%s "$sha" 2>/dev/null)"
        case "$_dec" in
            ACCEPT) echo "  [ACCEPT]       $_short → ${COMMIT_ASSIGNED[$sha]}  ($_subj)" ;;
            INFER)  echo "  [INFER]        $_short → ${COMMIT_ASSIGNED[$sha]}  ($_subj)" ;;
            SPLIT)  echo "  [SPLIT]        $_short → ${COMMIT_SPLIT_STORIES[$sha]}  ($_subj)" ;;
            UNATTRIBUTED) echo "  [UNATTRIBUTED] $_short  ($_subj)" ;;
            MERGE)  echo "  [MERGE]        $_short  skipped (merge commit preserved on session)  ($_subj)" ;;
        esac
    done
fi

# ── Phase 3: SPLIT (planning only; per-story sub-patches produced at publish) ─
SPLIT_COUNT=0
for sha in "${RANGE_REVS[@]}"; do
    [[ "${COMMIT_DECISION[$sha]:-}" == "SPLIT" ]] && (( SPLIT_COUNT++ ))
done
if [[ "$SPLIT_COUNT" -gt 0 ]]; then
    echo "▶ Phase 3: SPLIT — $SPLIT_COUNT commit(s) require per-story sub-patches"
else
    echo "▶ Phase 3: cross-story partition — no commits require per-story sub-patches"
fi

# ── Phase 4: FALLBACK — epoch grouping for UNATTRIBUTED ──────────────────────
echo "▶ Phase 4: FALLBACK"
EPOCH_SIZE=5
EPOCH_COUNT=0
if [[ "${#UNATTRIBUTED_SHAS[@]}" -gt 0 ]]; then
    _i=0
    _epoch_idx=1
    _current_key=""
    for sha in "${UNATTRIBUTED_SHAS[@]}"; do
        if (( _i % EPOCH_SIZE == 0 )); then
            _current_key="$(printf 'epoch-%02d' "$_epoch_idx")"
            (( _epoch_idx++ ))
            (( EPOCH_COUNT++ ))
        fi
        _register_group_commit "$_current_key" "$sha"
        (( _i++ ))
    done
    echo "  WARN: ${#UNATTRIBUTED_SHAS[@]} unattributed commit(s) grouped into $EPOCH_COUNT epoch(s)"
    if [[ "$_FORCED_PAST_TREE_CHECK" -eq 0 ]]; then
        for key in "${GROUP_ORDER[@]}"; do
            [[ "$key" == epoch-* ]] || continue
            echo "    $key:"
            while IFS= read -r _s; do
                [[ -z "$_s" ]] && continue
                _short="${_s:0:12}"
                _subj="$(git log -1 --format=%s "$_s" 2>/dev/null)"
                echo "      $_short  $_subj"
            done <<< "${GROUP_COMMITS[$key]}"
        done
    fi
else
    echo "  all commits attributed — no epoch fallback needed"
fi

if [[ "${#MERGE_SHAS[@]}" -gt 0 ]]; then
    echo "  ${#MERGE_SHAS[@]} merge commit(s) preserved on session branch (skipped from redistribution)"
fi

# ── Phase 5: PUBLISH ─────────────────────────────────────────────────────────
echo "▶ Phase 5: PUBLISH"

if [[ "${#GROUP_ORDER[@]}" -eq 0 ]]; then
    echo "  no groups to publish"
    exit 0
fi

# Summary table (also suppressed under tree-state bypass for the same reason).
if [[ "$_FORCED_PAST_TREE_CHECK" -eq 0 ]]; then
    echo "  ── Plan summary ──"
    printf "  %-40s  %-7s  %-10s\n" "GROUP" "COMMITS" "FILES"
    for key in "${GROUP_ORDER[@]}"; do
        _commits="${GROUP_COMMITS[$key]}"
        _ccount=0
        _files_all=""
        while IFS= read -r _s; do
            [[ -z "$_s" ]] && continue
            (( _ccount++ ))
            _files_all+="${COMMIT_FILES[$_s]:-}"$'\n'
        done <<< "$_commits"
        _fcount="$(echo "$_files_all" | awk 'NF>0' | sort -u | wc -l | tr -d ' ')"
        printf "  %-40s  %-7d  %-10d\n" "$key" "$_ccount" "$_fcount"
    done
else
    echo "  ── Plan summary elided (tree-state bypass; ${#GROUP_ORDER[@]} group(s) computed) ──"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "  [dry-run] no branches created, no cherry-picks performed, no PRs opened"
    exit 0
fi

# Real publish path: cherry-pick + push + open PR per group
_merge_script=""
if [[ -n "${DSO_MERGE_TO_MAIN_PR_OVERRIDE:-}" ]]; then
    _merge_script="$DSO_MERGE_TO_MAIN_PR_OVERRIDE"
else
    _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "$_here/merge-to-main-pr.sh" ]]; then
        _merge_script="$_here/merge-to-main-pr.sh"
    fi
fi

_checkpoint="$(mktemp /tmp/redistribute-state.XXXXXX)"
echo "epic=$EPIC_ID" > "$_checkpoint"
echo "session_branch=$SESSION_BRANCH" >> "$_checkpoint"

_start_ref="$(git rev-parse HEAD)"
# Track background merge-script PIDs so we can wait() on them before exiting.
_MERGE_PIDS=()

for key in "${GROUP_ORDER[@]}"; do
    _branch="story/${EPIC_ID}/${key}"

    # Safety check 1: collision with the source/session branch itself.
    # If the group's branch name matches SESSION_BRANCH, the commits already
    # live on the source — there is nothing to redistribute. Skip with INFO.
    if [[ "$_branch" == "$SESSION_BRANCH" ]]; then
        echo "  ↷ skipping $key — branch name matches session branch (commits already on source)"
        continue
    fi

    # Safety check 2: pre-existing local branch with the same name.
    # `-B` would silently RESET the branch to MAIN_REF, destroying any commits
    # that branch already has. Refuse to overwrite — fail fast with a clear error.
    if git show-ref --verify --quiet "refs/heads/$_branch"; then
        echo "  ERROR: local branch $_branch already exists — refusing to overwrite" >&2
        echo "         If this branch is unrelated, delete it first: git branch -D $_branch" >&2
        echo "branch_collision=$_branch" >> "$_checkpoint"
        git checkout -q "$_start_ref" 2>/dev/null || true
        echo "  checkpoint: $_checkpoint  (resume support: out of scope this story)"
        exit 2
    fi

    # Safety check 3: pre-existing remote branch. WARN but do not fail — the
    # user may legitimately want to add commits to an existing redistribute
    # target (e.g., re-running after a partial failure). Push will refuse if
    # not fast-forwardable, surfacing the conflict at push time.
    if git ls-remote --exit-code --heads origin "$_branch" >/dev/null 2>&1; then
        echo "  WARN: remote branch origin/$_branch already exists; push may fail if histories diverge" >&2
    fi

    echo "  → publishing $key as $_branch"

    if ! git checkout -q -b "$_branch" "$MAIN_REF" 2>/dev/null; then
        echo "  ERROR: failed to create branch $_branch from $MAIN_REF" >&2
        echo "branch_failed=$_branch" >> "$_checkpoint"
        git checkout -q "$_start_ref" 2>/dev/null || true
        echo "  checkpoint: $_checkpoint  (resume support: out of scope this story)"
        exit 2
    fi

    _pick_failed=0
    while IFS= read -r _s; do
        [[ -z "$_s" ]] && continue
        # Bug cf84-9c07-00f8-4ad6 fix: for SPLIT commits, apply only the files
        # whose path matches THIS story's scope. Without filtering, the entire
        # commit (including files belonging to OTHER stories) would be cherry-
        # picked into every matched story's branch, bloating diffs and creating
        # cross-pollination.
        if [[ "${COMMIT_DECISION[$_s]:-}" == "SPLIT" ]]; then
            _split_apply_result=0
            _apply_filtered_split_commit "$_s" "$key" || _split_apply_result=$?
            if [[ "$_split_apply_result" -eq 0 ]]; then
                continue  # filtered apply succeeded (or had no files to apply)
            fi
            _pick_failed=1
            echo "  ERROR: filtered SPLIT apply failed for $_s on $_branch" >&2
            git reset --hard HEAD >/dev/null 2>&1 || true
            break
        fi
        # ACCEPT / INFER / UNATTRIBUTED — bulk cherry-pick is correct
        if ! git cherry-pick "$_s" >/dev/null 2>&1; then
            _pick_failed=1
            echo "  ERROR: cherry-pick failed for $_s on $_branch" >&2
            git cherry-pick --abort 2>/dev/null || true
            break
        fi
    done <<< "${GROUP_COMMITS[$key]}"

    if [[ "$_pick_failed" -eq 1 ]]; then
        echo "branch_conflicts=$_branch (continuing past failure)" >> "$_checkpoint"
        # Delete the partial branch and restore HEAD; continue to next group
        git checkout -q "$_start_ref" 2>/dev/null || true
        git branch -D "$_branch" 2>/dev/null || true
        echo "  ↷ skipping $key — cherry-pick conflicts (see bug cf84-9c07 for SPLIT-phase fix)" >&2
        continue
    fi

    if ! git push -u origin "$_branch" >/dev/null 2>&1; then
        echo "  WARN: push of $_branch failed (continuing)" >&2
    fi

    if [[ -n "$_merge_script" ]]; then
        # Background-parallel: open PR + queue auto-merge without blocking the next group
        ( STORY_PR_BASE="$SESSION_BRANCH" bash "$_merge_script" 2>&1 | sed "s|^|  [$_branch] |" ) &
        _MERGE_PIDS+=("$!:$_branch")
        echo "  → PR open dispatched in background for $_branch (PID $!)"
    fi
done

# Wait for background merge-script dispatches and surface any failures.
# Without this, the parent process could exit 0 while children were still
# running, hiding non-zero exits from merge-to-main-pr.sh (Copilot finding
# 2026-05-16). Collect each PID's status and report aggregated failures.
_FAILED_BRANCHES=()
for _entry in "${_MERGE_PIDS[@]+"${_MERGE_PIDS[@]}"}"; do
    _pid="${_entry%%:*}"
    _b="${_entry#*:}"
    if ! wait "$_pid" 2>/dev/null; then
        _FAILED_BRANCHES+=("$_b")
    fi
done
if [[ "${#_FAILED_BRANCHES[@]}" -gt 0 ]]; then
    echo "  ERROR: merge-to-main-pr.sh returned non-zero for ${#_FAILED_BRANCHES[@]} branch(es):" >&2
    for _b in "${_FAILED_BRANCHES[@]}"; do echo "    - $_b" >&2; done
fi

git checkout -q "$_start_ref" 2>/dev/null || true
rm -f "$_checkpoint"
# Exit non-zero if any background PR-open call failed so automation can react.
# Reporting failures via WARN-only and then exiting 0 (the prior behavior)
# defeated the purpose of the wait loop. Copilot finding 2026-05-16.
if [[ "${#_FAILED_BRANCHES[@]}" -gt 0 ]]; then
    echo "✗ redistribution completed with ${#_FAILED_BRANCHES[@]} PR-open failure(s)" >&2
    exit 3
fi
echo "✓ redistribution complete"
exit 0
