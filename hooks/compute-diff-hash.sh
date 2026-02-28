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

{
    git diff HEAD -- ':!.beads/' ':!app/tests/e2e/snapshots/*.png' ':!app/tests/unit/templates/snapshots/*.html' 2>/dev/null || true
    git diff --cached HEAD -- ':!.beads/' ':!app/tests/e2e/snapshots/*.png' ':!app/tests/unit/templates/snapshots/*.html' 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null | { grep -v '^\.beads/' || true; } | { grep -v '^app/tests/e2e/snapshots/.*\.png$' || true; } | { grep -v '^app/tests/unit/templates/snapshots/.*\.html$' || true; } | while IFS= read -r f; do
        echo "untracked: $f"
        cat "$f" 2>/dev/null || true
    done
} | hash_stdin
