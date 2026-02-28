#!/usr/bin/env bash
# .claude/hooks/compute-diff-hash.sh
# Shared utility: computes a SHA-256 hash of the current working tree diff.
#
# Includes staged changes, unstaged changes, and untracked file contents.
# Excludes .beads/ files (issue tracker metadata shouldn't affect code hashes).
#
# Usage:
#   HASH=$(.claude/hooks/compute-diff-hash.sh)
#
# Output: a single SHA-256 hex string on stdout

set -euo pipefail

# Source shared dependency library for hash_stdin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/deps.sh"

# Pathspec exclusions for non-reviewable files (binary, snapshots, images, docs)
EXCLUDE_PATHSPECS=(
    ':!.beads/'
    ':!app/tests/e2e/snapshots/'
    ':!app/tests/unit/templates/snapshots/*.html'
    ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.gif' ':!*.svg' ':!*.ico' ':!*.webp'
    ':!*.pdf' ':!*.docx'
)

# Grep pattern to filter untracked non-reviewable files
NON_REVIEWABLE_PATTERN='^\.beads/|^app/tests/e2e/snapshots/|^app/tests/unit/templates/snapshots/.*\.html$|\.(png|jpg|jpeg|gif|svg|ico|webp|pdf|docx)$'

{
    git diff HEAD -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
    git diff --cached HEAD -- "${EXCLUDE_PATHSPECS[@]}" 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null | { grep -v -E "$NON_REVIEWABLE_PATTERN" || true; } | while IFS= read -r f; do
        echo "untracked: $f"
        cat "$f" 2>/dev/null || true
    done
} | hash_stdin
