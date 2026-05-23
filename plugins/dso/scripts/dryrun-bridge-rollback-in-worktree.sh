#!/usr/bin/env bash
# Runs rollback-bridge-cutover.sh inside a throwaway git worktree.
# The throwaway worktree is always removed on exit (trap EXIT).
# Usage: bash dryrun-bridge-rollback-in-worktree.sh
# Env:
#   DSO_DRYRUN_REPO_ROOT   — source repo root (default: git rev-parse --show-toplevel)
#   DSO_DRYRUN_CUTOVER_SHA — passed through to rollback-bridge-cutover.sh as
#                            DSO_ROLLBACK_CUTOVER_SHA (required)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${DSO_DRYRUN_REPO_ROOT:-$(git rev-parse --show-toplevel)}"
_ROLLBACK_SCRIPT="${DSO_DRYRUN_ROLLBACK_SCRIPT:-$SCRIPT_DIR/rollback-bridge-cutover.sh}"

if [[ -z "${DSO_DRYRUN_CUTOVER_SHA:-}" ]]; then
    echo "ERROR: DSO_DRYRUN_CUTOVER_SHA is required" >&2
    exit 2
fi

THROWAWAY="$(mktemp -d /tmp/dryrun-rollback.XXXXXX)"
git -C "$REPO_ROOT" worktree add "$THROWAWAY" HEAD

trap 'git -C "$REPO_ROOT" worktree remove "$THROWAWAY" --force 2>/dev/null; rm -rf "$THROWAWAY"' EXIT

# SKIP_PUSH=1 keeps the dryrun fully local — no real push to origin and no
# gh run watch against the production branch.
DSO_ROLLBACK_REPO_ROOT="$THROWAWAY" \
DSO_ROLLBACK_CUTOVER_SHA="$DSO_DRYRUN_CUTOVER_SHA" \
DSO_ROLLBACK_SKIP_PUSH=1 \
bash "$_ROLLBACK_SCRIPT"

echo "DRYRUN OK: throwaway worktree cleaned up"
