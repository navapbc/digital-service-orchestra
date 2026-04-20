#!/usr/bin/env bash
# hook-boundary: enforcement
# hooks/pre-commit-enforcement-boundary-check.sh
# git pre-commit hook: annotation-driven enforcement boundary check.
#
# Blocks commits where a file marked with '# hook-boundary: enforcement'
# in its header also sources hook-error-handler.sh.
#
# Enforcement hooks are intentionally strict / exit-non-zero and must NOT
# use the shared fail-open ERR handler.
#
# Detection strategy: annotation-driven (no hardcoded file list).
# For each staged file:
#   1. If it contains '# hook-boundary: enforcement' → it is an enforcement hook
#   2. If that same file also contains a 'source' call to 'hook-error-handler.sh'
#      → violation: block the commit and name the offending file

set -euo pipefail

# Pre-commit hooks are invoked by git from the repository root, so all
# git commands below operate against the correct working tree without
# needing an explicit REPO_ROOT.

violations=()

while IFS= read -r staged_file; do
    [[ -z "$staged_file" ]] && continue

    # Read the staged blob content (works even for files not on disk,
    # e.g. during index-only operations).
    blob_content=$(git show ":${staged_file}" 2>/dev/null) || continue

    has_boundary=0
    has_handler=0

    if echo "$blob_content" | grep -qF '# hook-boundary: enforcement' 2>/dev/null; then
        has_boundary=1
    fi

    if echo "$blob_content" | grep -qE '^[[:space:]]*(source|\\.)[[:space:]]+.*hook-error-handler\.sh' 2>/dev/null; then
        has_handler=1
    fi

    if [[ "$has_boundary" -eq 1 && "$has_handler" -eq 1 ]]; then
        violations+=("$staged_file")
    fi
done < <(git diff --cached --name-only)

if [[ "${#violations[@]}" -gt 0 ]]; then
    echo "ERROR: enforcement-boundary-check: enforcement hook(s) must NOT source hook-error-handler.sh" >&2
    echo "" >&2
    echo "Enforcement hooks use strict exit-non-zero semantics and must NOT use" >&2
    echo "the shared fail-open ERR handler (hook-error-handler.sh)." >&2
    echo "" >&2
    echo "Offending file(s):" >&2
    for f in "${violations[@]}"; do
        echo "  $f" >&2
    done
    echo "" >&2
    echo "Fix: remove the 'source hook-error-handler.sh' line from the above file(s)," >&2
    echo "     or remove the '# hook-boundary: enforcement' annotation if the file" >&2
    echo "     is not an enforcement hook." >&2
    exit 1
fi

exit 0
