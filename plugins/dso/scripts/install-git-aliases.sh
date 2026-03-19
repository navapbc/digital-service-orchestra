#!/usr/bin/env bash
set -euo pipefail
# scripts/install-git-aliases.sh
# Registers project-specific git aliases in the local repo config.
#
# Aliases installed:
#   git revert-safe   — Wrapper around `git revert` that strips .tickets/ files
#                       from the revert commit by default. See scripts/git-revert-safe.sh.
#
# Usage:
#   bash scripts/install-git-aliases.sh
#
# Idempotent — safe to run multiple times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the repo root via git (works from any nested directory).
REPO_ROOT="$(git rev-parse --show-toplevel)"

# ── Register aliases ──────────────────────────────────────────────────────────

# shellcheck disable=SC2016
git config alias.revert-safe \
    '!REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/plugins/dso/scripts/git-revert-safe.sh" "$@"'

# ── Confirmation ──────────────────────────────────────────────────────────────

echo "Git aliases installed (repo-local):"
echo "  git revert-safe  →  scripts/git-revert-safe.sh"
