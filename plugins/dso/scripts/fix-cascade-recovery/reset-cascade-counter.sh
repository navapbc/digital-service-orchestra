#!/usr/bin/env bash
# Reset the cascade circuit-breaker counter for the current worktree.
#
# Mirrors the hash derivation in:
#   hooks/cascade-circuit-breaker.sh
#   hooks/track-cascade-failures.sh
#   hooks/lib/pre-edit-write-functions.sh
# (paths relative to ${CLAUDE_PLUGIN_ROOT})
#
# Counter path (gate — consumed by the hooks above):
#   /tmp/claude-cascade-<worktree-hash>/counter

set -euo pipefail

WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$WORKTREE_ROOT" ]]; then
    echo "[reset-cascade-counter] not in a git worktree; nothing to reset" >&2
    exit 0
fi

if command -v md5 &>/dev/null; then
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5)
elif command -v md5sum &>/dev/null; then
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5sum | cut -d' ' -f1)
else
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | tr '/' '_')
fi

STATE_DIR="/tmp/claude-cascade-${WT_HASH}"
COUNTER_FILE="$STATE_DIR/counter"
HASH_FILE="$STATE_DIR/last-error-hash"

mkdir -p "$STATE_DIR"
echo 0 > "$COUNTER_FILE"
rm -f "$HASH_FILE"

echo "[reset-cascade-counter] reset $COUNTER_FILE" >&2
