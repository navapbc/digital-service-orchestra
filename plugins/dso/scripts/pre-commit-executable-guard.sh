#!/bin/bash
# pre-commit-executable-guard.sh — Prevent scripts from losing their executable bit
#
# Compares the staged file mode against the mode on the main branch (or the
# previous commit if not on a branch). If a file that was 100755 is staged as
# 100644, the commit is blocked with a clear error message.
#
# Checks all staged .sh files (with a shebang line) across the entire repo.

set -euo pipefail

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"

# Determine the reference to compare against.
# Use main if it exists, otherwise HEAD (covers initial commits).
if git rev-parse --verify main >/dev/null 2>&1; then
    REF="main"
else
    REF="HEAD"
fi

errors=0

# Use a temp file to avoid pipe subshell (which would hide $errors changes)
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
git diff --cached --name-only --diff-filter=M | tee "$tmpfile" > /dev/null

while IFS= read -r file; do
    [ -z "$file" ] && continue

    # Only check .sh files
    case "$file" in
        *.sh) ;;
        *) continue ;;
    esac

    # Skip files that don't exist (deleted)
    [ -f "$REPO_ROOT/$file" ] || continue

    # Only check files with a shebang
    head -1 "$REPO_ROOT/$file" 2>/dev/null | grep -q '^#!' || continue

    # Get the mode in the reference commit
    ref_mode=$(git ls-tree "$REF" -- "$file" 2>/dev/null | awk '{print $1}')
    [ -z "$ref_mode" ] && continue  # New file, nothing to compare

    # Get the staged mode (from the index)
    staged_mode=$(git ls-files -s -- "$file" 2>/dev/null | awk '{print $1}')
    [ -z "$staged_mode" ] && continue

    if [ "$ref_mode" = "100755" ] && [ "$staged_mode" = "100644" ]; then
        echo "ERROR: $file lost its executable bit (was 100755, staged as 100644)"
        echo "  Fix: chmod +x $file && git add $file"
        errors=1
    fi
done < "$tmpfile"

exit "$errors"
