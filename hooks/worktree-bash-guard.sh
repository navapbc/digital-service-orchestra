#!/usr/bin/env bash
# lockpick-workflow/hooks/worktree-bash-guard.sh
# PreToolUse hook: block Bash commands that cd into the main repo from a worktree
#
# Enforces CLAUDE.md rule 11:
#   "Never edit main repo files from a worktree session"
#
# How it works:
#   - If not in a worktree, allows everything (exit 0)
#   - If in a worktree, checks if the Bash command includes a `cd` to the main repo
#   - Safe patterns (sprintend-merge.sh, resolve-conflicts.sh, bd commands): allowed
#   - Read-only git/bd commands that reference main repo path: allowed
#   - cd into main repo + write operations: BLOCKED
#
# Note: Edit/Write tools are separately guarded by worktree-edit-guard.sh.

HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"worktree-bash-guard.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# --- Not a worktree? Allow everything. ---
_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$_TOPLEVEL" ]]; then
    exit 0
fi
# A worktree has .git as a file (not a directory)
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

COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# --- Resolve paths ---
WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$WORKTREE_ROOT" ]]; then
    exit 0
fi

MAIN_GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
if [[ -z "$MAIN_GIT_DIR" ]]; then
    exit 0
fi

MAIN_GIT_DIR=$(cd "$WORKTREE_ROOT" && cd "$MAIN_GIT_DIR" && pwd)
MAIN_REPO_ROOT=$(dirname "$MAIN_GIT_DIR")

WORKTREE_ROOT="${WORKTREE_ROOT%/}"
MAIN_REPO_ROOT="${MAIN_REPO_ROOT%/}"

# --- Does the command reference the main repo at all? ---
if [[ "$COMMAND" != *"$MAIN_REPO_ROOT"* ]]; then
    exit 0
fi

# --- Allow-list: safe scripts that legitimately operate on both repos ---
# sprintend-merge.sh: orchestrates worktree→main merge (authorized to cd into main)
# resolve-conflicts.sh: conflict resolution (may need to cd into main)
if [[ "$COMMAND" == *"sprintend-merge.sh"* ]] || \
   [[ "$COMMAND" == *"resolve-conflicts.sh"* ]]; then
    exit 0
fi

# --- Allow-list: bd (beads) commands are always safe ---
# bd uses .beads redirect so it doesn't need to write to the main repo directly.
# Allow `cd MAIN_REPO && bd ...` patterns.
if echo "$COMMAND" | grep -qE "bd[[:space:]]+(close|create|update|list|show|dep|search|ready|blocked|stats|q)[[:space:]]"; then
    exit 0
fi

# --- Allow-list: read-only patterns after cd to main repo ---
# Commands that cd to the main repo but only read (cat, git log, etc.)
CMD_AFTER_CD=$(echo "$COMMAND" | sed -n "s|.*cd[[:space:]]*['\"]\\?${MAIN_REPO_ROOT}['\"]\\?[[:space:]]*&&[[:space:]]*||p")
if [[ -n "$CMD_AFTER_CD" ]]; then
    if echo "$CMD_AFTER_CD" | grep -qE "^[[:space:]]*(cat|head|tail|less|more|ls|find|stat|wc|file) " || \
       echo "$CMD_AFTER_CD" | grep -qE "git[[:space:]]+(log|diff|show|status|rev-parse|branch|tag|ls-files|describe|remote|fetch|symbolic-ref|for-each-ref)" || \
       echo "$CMD_AFTER_CD" | grep -qE "lockpick-workflow/scripts/(validate|ci-status|orphaned-tasks)"; then
        exit 0
    fi
fi

# --- Check if the command actually cd's into the main repo ---
# Pattern: "cd /path/to/main/repo" possibly followed by && or ;
if echo "$COMMAND" | grep -qE "cd[[:space:]]+(\"$MAIN_REPO_ROOT\"|'$MAIN_REPO_ROOT'|$MAIN_REPO_ROOT)([[:space:]]|[;&\|]|$)"; then
    echo "BLOCKED: Bash command cd's into the main repo from a worktree session." >&2
    echo "" >&2
    echo "CLAUDE.md rule 11: \"Never edit main repo files from a worktree session.\"" >&2
    echo "  Command contains: cd $MAIN_REPO_ROOT" >&2
    echo "  Main repo:   $MAIN_REPO_ROOT" >&2
    echo "  Worktree:    $WORKTREE_ROOT" >&2
    echo "" >&2
    echo "Work on the worktree branch instead — merge to main via sprintend-merge.sh." >&2
    echo "If you need to run sprintend-merge.sh or resolve-conflicts.sh, those are allow-listed." >&2
    exit 2
fi

# Command references main repo path but doesn't cd into it — allow (e.g., reading files).
exit 0
