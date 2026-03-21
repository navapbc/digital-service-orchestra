#!/usr/bin/env bash
# .claude/hooks/cascade-circuit-breaker.sh
# PreToolUse hook: block Edit/Write when fix cascade threshold is reached
#
# Enforces CLAUDE.md rule 13:
#   "Never continue fixing after 5 cascading failures — run /dso:fix-cascade-recovery"
#
# Reads the cascade counter from the worktree-scoped state directory.
# If counter >= 5, blocks the edit (exit 2) with a message requiring
# the agent to enter the fix-cascade-recovery protocol.
#
# Passthrough (never blocked):
#   - .tickets/ files (issue tracking)
#   - CLAUDE.md and .claude/ files (configuration)
#   - /tmp/ files (temporary state)
#   - ~/.claude/ files (user config)
#   - KNOWN-ISSUES.md (documentation)
#
# Paired with track-cascade-failures.sh (PostToolUse on Bash).
#
# Error handling: explicit per-operation guards (|| exit 0) instead of a
# global ERR trap. The ERR trap approach caused the hook to silently exit 0
# on Linux CI when bash ERR semantics differed from macOS, preventing the
# hook from ever reaching exit 2 (the blocking path). Per-operation guards
# preserve fail-open behavior without interfering with intentional blocks.

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
source "$HOOK_DIR/lib/deps.sh" || exit 0

# --- Read hook input ---
INPUT=$(cat) || exit 0

TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name') || exit 0
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
    exit 0
fi

# --- Check file path for passthrough ---
FILE_PATH=$(parse_json_field "$INPUT" '.tool_input.file_path') || exit 0

# Allow non-code edits (issue tracking, config, docs, temp files).
# Split into two case blocks because $HOME expansion does not work
# inside a single case pattern list with | separators.
case "$FILE_PATH" in
    */.tickets/*|*/CLAUDE.md|*/.claude/*|/tmp/*)
        exit 0
        ;;
esac
case "$FILE_PATH" in
    "$HOME/.claude/"*|*/KNOWN-ISSUES.md|*/MEMORY.md)
        exit 0
        ;;
esac

# --- Resolve worktree-scoped state directory ---
WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$WORKTREE_ROOT" ]]; then
    exit 0
fi

if command -v md5 &>/dev/null; then
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5) || exit 0
elif command -v md5sum &>/dev/null; then
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5sum | cut -d' ' -f1) || exit 0
else
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | tr '/' '_') || exit 0
fi

STATE_DIR="/tmp/claude-cascade-${WT_HASH}"
COUNTER_FILE="$STATE_DIR/counter"

# --- No counter file means no cascade ---
if [[ ! -f "$COUNTER_FILE" ]]; then
    exit 0
fi

# --- Read counter ---
COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
if ! [[ "$COUNTER" =~ ^[0-9]+$ ]]; then
    exit 0
fi

# --- Enforce threshold ---
CASCADE_THRESHOLD=5

if (( COUNTER >= CASCADE_THRESHOLD )); then
    echo "BLOCKED: Fix cascade (rule 13). $COUNTER consecutive fixes produced different errors." >&2
    echo "Run /dso:fix-cascade-recovery to analyze root cause and reset." >&2
    echo "Manual reset: echo 0 > $COUNTER_FILE" >&2
    exit 2
fi

exit 0
