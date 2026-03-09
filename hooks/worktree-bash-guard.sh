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
#   - Safe patterns (merge-to-main.sh, resolve-conflicts.sh): allowed
#   - Read-only git/tk commands that reference main repo path: allowed
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
# Reuse _TOPLEVEL already computed above (avoids a redundant git rev-parse).
WORKTREE_ROOT="$_TOPLEVEL"
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
# merge-to-main.sh: orchestrates worktree→main merge (authorized to cd into main)
# resolve-conflicts.sh: conflict resolution (may need to cd into main)
if [[ "$COMMAND" == *"merge-to-main.sh"* ]] || \
   [[ "$COMMAND" == *"resolve-conflicts.sh"* ]]; then
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
    echo "  Command:   cd $MAIN_REPO_ROOT ..." >&2
    echo "  Main repo: $MAIN_REPO_ROOT" >&2
    echo "  Worktree:  $WORKTREE_ROOT" >&2
    echo "" >&2
    echo "HOW TO FIX:" >&2
    echo "  • Run the same command from the worktree root (current working directory)." >&2
    echo "  • Use REPO_ROOT=\$(git rev-parse --show-toplevel) instead of a hardcoded path." >&2
    echo "  • tk commands work from any directory — drop 'cd MAIN_REPO && tk ...' prefix." >&2
    echo "  • To merge worktree changes to main: \$REPO_ROOT/scripts/merge-to-main.sh (allow-listed)." >&2
    echo "  • To read a main-repo file: use the Read tool with the absolute path." >&2
    exit 2
fi

# --- Block git plumbing commands that operate on the worktree's object store ---
# git read-tree, write-tree, commit-tree can produce corrupt subtree-only trees
# when run from a worktree context without explicitly targeting the main repo.
# tk-sync-lib.sh correctly uses "git -C <main-repo>" — those are safe.
if echo "$COMMAND" | grep -qE "git[[:space:]]+(read-tree|write-tree|commit-tree)"; then
    # Allow if the command uses -C to target the main repo (correct usage)
    if echo "$COMMAND" | grep -qE "git[[:space:]]+-C[[:space:]]+['\"]?${MAIN_REPO_ROOT}['\"]?[[:space:]]+(read-tree|write-tree|commit-tree)"; then
        exit 0
    fi
    echo "BLOCKED: git plumbing command in worktree context without -C targeting the main repo." >&2
    echo "" >&2
    echo "git read-tree/write-tree/commit-tree can produce corrupt trees when run" >&2
    echo "directly in a worktree. Use 'git -C <main-repo-path>' to target the main repo." >&2
    echo "  Command:   $COMMAND" >&2
    echo "  Main repo: $MAIN_REPO_ROOT" >&2
    echo "  Worktree:  $WORKTREE_ROOT" >&2
    echo "" >&2
    echo "HOW TO FIX:" >&2
    echo "  • Use 'git -C $MAIN_REPO_ROOT read-tree ...' instead of bare 'git read-tree ...'" >&2
    echo "  • tk-sync-lib.sh already does this correctly — follow that pattern." >&2
    exit 2
fi

# Command references main repo path but doesn't cd into it — allow (e.g., reading files).
exit 0
