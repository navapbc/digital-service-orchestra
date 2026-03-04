#!/usr/bin/env bash
# lockpick-workflow/hooks/ticket-sync-push.sh
# PostToolUse hook: when a .tickets/ file is created or edited in a worktree,
# commits ONLY the changed .tickets/ files to main using git plumbing
# (detached-index via temporary GIT_INDEX_FILE, git commit-tree + git update-ref),
# then pushes to origin. The worktree's HEAD, index, and staged files are
# never touched.
#
# If the push is rejected (non-fast-forward), the hook fetches, rebases the
# ticket commit onto the new main tip, and retries once. If the retry fails,
# the error is logged to stderr and the hook exits 0 (non-blocking).
#
# After a successful push, .last-sync-hash at the worktree root is updated.
#
# Bug workaround (#20334): PostToolUse hooks with specific matchers fire for
# ALL tools, not just the matched tool. Guard on tool_name internally and
# always emit at least one byte of stdout to avoid the empty-stdout hook error.

# Guarantee exit 0 and non-empty stdout on any unexpected failure.
# _HOOK_HAS_OUTPUT=1 suppresses the {} fallback for intentional early exits.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
trap 'exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

# Only act on Edit or Write tool calls
TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
    _HOOK_HAS_OUTPUT=1; exit 0
fi

FILE_PATH=$(parse_json_field "$INPUT" '.tool_input.file_path')
if [[ -z "$FILE_PATH" ]]; then
    _HOOK_HAS_OUTPUT=1; exit 0
fi

# Only act on files inside a .tickets/ directory
if [[ "$FILE_PATH" != *"/.tickets/"* ]]; then
    _HOOK_HAS_OUTPUT=1; exit 0
fi

# Only act inside a worktree (.git must be a FILE, not a directory).
# In the main repo, .git is a directory. In a worktree, .git is a file
# containing "gitdir: <path>" pointing to the main repo's worktrees entry.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { _HOOK_HAS_OUTPUT=1; exit 0; }
if [[ ! -f "$REPO_ROOT/.git" ]]; then
    _HOOK_HAS_OUTPUT=1; exit 0
fi

# Ensure the file actually exists (guard against intermediate edits or missing files)
if [[ ! -f "$FILE_PATH" ]]; then
    _HOOK_HAS_OUTPUT=1; exit 0
fi

# ── Detached-index commit mechanism ─────────────────────────────────────────
# We build a commit on refs/heads/main without touching the worktree's index.

MAIN_BRANCH="main"
MAIN_REF=$(git rev-parse "refs/heads/${MAIN_BRANCH}" 2>/dev/null) || MAIN_REF=""

# Create a temporary index file path. We use mktemp to get a unique path, then
# immediately remove the empty file so git can create a fresh binary index.
# (git read-tree fails with "index file smaller than expected" on a 0-byte file.)
TMPINDEX=$(mktemp)
rm -f "$TMPINDEX"
# Ensure temp file is cleaned up on exit (best-effort; hook exits 0 regardless)
_cleanup_tmpindex() { rm -f "$TMPINDEX"; }
trap '_cleanup_tmpindex; if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT

# Seed the temporary index from main's .tickets tree (if main exists and has .tickets)
export GIT_INDEX_FILE="$TMPINDEX"

if [[ -n "$MAIN_REF" ]]; then
    # Read the existing .tickets tree from main into the temp index
    git read-tree --prefix=.tickets/ "${MAIN_REF}:.tickets" 2>/dev/null || true
fi

# Compute the path of the changed file relative to the repo root
REL_PATH="${FILE_PATH#"$REPO_ROOT/"}"

# Stage the changed file into the detached index
# git update-index --add --cacheinfo <mode>,<blob>,<path>
BLOB_HASH=$(git hash-object -w "$FILE_PATH" 2>/dev/null) || { unset GIT_INDEX_FILE; _HOOK_HAS_OUTPUT=1; exit 0; }
git update-index --add --cacheinfo "100644,${BLOB_HASH},${REL_PATH}" 2>/dev/null || { unset GIT_INDEX_FILE; _HOOK_HAS_OUTPUT=1; exit 0; }

# Write the tree object from the detached index
NEW_TREE=$(git write-tree 2>/dev/null) || { unset GIT_INDEX_FILE; _HOOK_HAS_OUTPUT=1; exit 0; }

unset GIT_INDEX_FILE

# Build the commit message
SHORT_PATH=$(basename "$FILE_PATH")
COMMIT_MSG="chore: sync ticket changes from worktree [skip ci]

Updated: ${REL_PATH}"

# Create the commit object
if [[ -n "$MAIN_REF" ]]; then
    NEW_COMMIT=$(git commit-tree "$NEW_TREE" -p "$MAIN_REF" -m "$COMMIT_MSG" 2>/dev/null) || { _HOOK_HAS_OUTPUT=1; exit 0; }
else
    # First commit — no parent (fresh repo)
    NEW_COMMIT=$(git commit-tree "$NEW_TREE" -m "$COMMIT_MSG" 2>/dev/null) || { _HOOK_HAS_OUTPUT=1; exit 0; }
fi

# Update local refs/heads/main atomically
# Use $MAIN_REF as the "expected old value" guard (empty string OK for fresh repo)
if [[ -n "$MAIN_REF" ]]; then
    git update-ref "refs/heads/${MAIN_BRANCH}" "$NEW_COMMIT" "$MAIN_REF" 2>/dev/null || { _HOOK_HAS_OUTPUT=1; exit 0; }
else
    git update-ref "refs/heads/${MAIN_BRANCH}" "$NEW_COMMIT" 2>/dev/null || { _HOOK_HAS_OUTPUT=1; exit 0; }
fi

# ── Push with retry ──────────────────────────────────────────────────────────
push_with_retry() {
    local attempt=0

    while true; do
        # Attempt push — capture stderr on the first try to avoid a redundant
        # network call (fixes double-push issue).
        local push_stderr
        push_stderr=$(git push origin "refs/heads/${MAIN_BRANCH}:refs/heads/${MAIN_BRANCH}" 2>&1) && return 0

        if [[ $attempt -ge 1 ]]; then
            # Second failure — log and give up
            printf "ticket-sync-push: push failed after retry (attempt %d): %s\n" "$((attempt + 1))" "$push_stderr" >&2
            return 1
        fi

        # Non-fast-forward: fetch and rebase the ticket commit onto new tip
        git fetch origin "${MAIN_BRANCH}" 2>/dev/null || {
            printf "ticket-sync-push: fetch failed during retry: could not fetch origin/%s\n" "$MAIN_BRANCH" >&2
            return 1
        }

        local NEW_MAIN_TIP
        NEW_MAIN_TIP=$(git rev-parse "origin/${MAIN_BRANCH}" 2>/dev/null) || {
            printf "ticket-sync-push: could not resolve origin/%s after fetch\n" "$MAIN_BRANCH" >&2
            return 1
        }

        # Rebase: create a new commit on top of the fetched tip using the same tree
        local REBASED_COMMIT
        REBASED_COMMIT=$(git commit-tree "$NEW_TREE" -p "$NEW_MAIN_TIP" -m "$COMMIT_MSG" 2>/dev/null) || {
            printf "ticket-sync-push: commit-tree failed during rebase retry\n" >&2
            return 1
        }

        # Update local ref to rebased commit
        git update-ref "refs/heads/${MAIN_BRANCH}" "$REBASED_COMMIT" 2>/dev/null || {
            printf "ticket-sync-push: update-ref failed during rebase retry\n" >&2
            return 1
        }

        attempt=$((attempt + 1))
    done
}

# Attempt push and update .last-sync-hash on success
if push_with_retry 2>/dev/null; then
    # Write the tree hash of main:.tickets (not the commit hash) so that
    # _sync_from_main() in scripts/tk can compare apples-to-apples.
    TREE_HASH=$(git rev-parse "refs/heads/${MAIN_BRANCH}:.tickets" 2>/dev/null) || TREE_HASH=""
    if [[ -n "$TREE_HASH" ]]; then
        printf "%s\n" "$TREE_HASH" > "$REPO_ROOT/.last-sync-hash" 2>/dev/null || true
    fi
else
    # Push failed — log warning to stderr and continue (hook exits 0)
    printf "ticket-sync-push: push failed for %s — ticket changes saved locally but not pushed to origin\n" "$SHORT_PATH" >&2
fi

_HOOK_HAS_OUTPUT=1
exit 0
