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
# After a successful push, .tickets/.last-sync-hash is updated.
#
# Bug workaround (#20334): PostToolUse hooks with specific matchers fire for
# ALL tools, not just the matched tool. Guard on tool_name internally and
# always emit at least one byte of stdout to avoid the empty-stdout hook error.

# Guarantee exit 0 and non-empty stdout on any unexpected failure.
# _HOOK_HAS_OUTPUT=1 suppresses the {} fallback for intentional early exits.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
trap 'exit 0' ERR

# Source shared dependency library and ticket-sync lib
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# Resolve the repo root for tk-sync-lib.sh path resolution
# (REPO_ROOT may not be set yet at this point; use git rev-parse)
_HOOK_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || _HOOK_REPO_ROOT=""
if [[ -n "$_HOOK_REPO_ROOT" ]]; then
    source "$_HOOK_REPO_ROOT/scripts/tk-sync-lib.sh" 2>/dev/null || true
fi

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

# ── Delegate to _sync_ticket_file (from scripts/tk-sync-lib.sh) ──────────────
# _sync_ticket_file performs the detached-index commit and push-with-retry.
# It always exits 0 (fire-and-forget) and logs errors to stderr.
export REPO_ROOT
if declare -f _sync_ticket_file > /dev/null 2>&1; then
    _sync_ticket_file "$FILE_PATH" || true
else
    # Fallback: lib failed to load — log and continue
    printf "ticket-sync-push: tk-sync-lib.sh not loaded, skipping sync for %s\n" \
        "$(basename "$FILE_PATH")" >&2
fi

_HOOK_HAS_OUTPUT=1
exit 0
