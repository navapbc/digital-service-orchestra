#!/usr/bin/env bash
# .claude/hooks/worktree-edit-guard.sh
# PreToolUse hook: block Edit/Write calls targeting main repo from a worktree
#
# Enforces CLAUDE.md rule 12:
#   "Never edit files in the main repo's working tree from a worktree session"
#
# How it works:
#   - If not in a worktree, allows everything (exit 0)
#   - If in a worktree, checks if the target file_path is inside the worktree
#   - Files inside the worktree: allowed
#   - Files inside the main repo (but not worktree): BLOCKED
#   - Files outside both (e.g., /tmp, ~/.claude): allowed
#
# bd commands are unaffected — they use Bash tool, not Edit/Write.

# Log unexpected errors to JSONL and exit cleanly (never surface to user)
# Intentional blocks (exit 2) are NOT affected by this trap.
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"worktree-edit-guard.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# --- Not a worktree? Allow everything. ---
# Use git rev-parse to find the toplevel, then check if .git there is a file
# (worktree indicator). Don't rely on CWD which may not be the repo root.
_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$_TOPLEVEL" ]]; then
    exit 0
fi
if [ -d "$_TOPLEVEL/.git" ]; then
    exit 0
fi
if [ ! -f "$_TOPLEVEL/.git" ]; then
    exit 0
fi

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# --- Read hook input ---
INPUT=$(cat)

FILE_PATH=$(parse_json_field "$INPUT" '.tool_input.file_path')
if [[ -z "$FILE_PATH" ]]; then
    # No file_path in input — nothing to guard
    exit 0
fi

# --- Resolve paths ---
WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$WORKTREE_ROOT" ]]; then
    exit 0
fi

# Get main repo root via the shared git directory
MAIN_GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
if [[ -z "$MAIN_GIT_DIR" ]]; then
    exit 0
fi

# Resolve to absolute path (git-common-dir may be relative)
MAIN_GIT_DIR=$(cd "$WORKTREE_ROOT" && cd "$MAIN_GIT_DIR" && pwd)
MAIN_REPO_ROOT=$(dirname "$MAIN_GIT_DIR")

# --- Check file location ---
# Normalize: ensure paths end without trailing slash for consistent prefix matching
WORKTREE_ROOT="${WORKTREE_ROOT%/}"
MAIN_REPO_ROOT="${MAIN_REPO_ROOT%/}"

# File is inside the worktree? Allow.
if [[ "$FILE_PATH" == "$WORKTREE_ROOT"/* || "$FILE_PATH" == "$WORKTREE_ROOT" ]]; then
    exit 0
fi

# File is inside the main repo? Block.
if [[ "$FILE_PATH" == "$MAIN_REPO_ROOT"/* || "$FILE_PATH" == "$MAIN_REPO_ROOT" ]]; then
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    [[ -z "$TOOL_NAME" ]] && TOOL_NAME="Edit/Write"
    echo "BLOCKED: $TOOL_NAME targeting main repo from worktree session." >&2
    echo "" >&2
    echo "CLAUDE.md rule 12: \"Never edit files in the main repo's working tree from a worktree session.\"" >&2
    echo "  Target file: $FILE_PATH" >&2
    echo "  Main repo:   $MAIN_REPO_ROOT" >&2
    echo "  Worktree:    $WORKTREE_ROOT" >&2
    echo "" >&2
    echo "Edit the file on the worktree branch instead — the merge will propagate it to main." >&2
    exit 2
fi

# File is outside both repo and worktree (e.g. /tmp, ~/.claude) — allow.
exit 0
