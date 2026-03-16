#!/usr/bin/env bash
# Rule: no-repo-source-mktemp
# Detects mktemp calls that create temp files inside the repo's source tree
# (e.g., mktemp "$REPO_ROOT/app/src/..."). Tests should create temp files
# in /tmp/ or $TMPDIR and use a fake repo structure for isolation.
#
# Rule contract:
#   - Receives a file path as $1
#   - Outputs violations as file:line:no-repo-source-mktemp:message to stdout
#   - Exits 0 (violations reported via stdout, not exit code)
#
# Only checks .sh and .bash files (skips other extensions).

set -uo pipefail

file="$1"

# Only check bash/shell files
case "$file" in
    *.sh|*.bash) ;;
    *) exit 0 ;;
esac

# Check if file contains mktemp calls referencing repo paths
# Patterns: mktemp "$REPO_ROOT/...", mktemp "${REPO_ROOT}/..."
if ! grep -qE 'mktemp\s+["'\''"]?\$(\{?REPO_ROOT\}?|REPO_ROOT)/' "$file" 2>/dev/null; then
    exit 0
fi

# Report each violation
line_num=0
while IFS= read -r line; do
    (( line_num++ ))
    if echo "$line" | grep -qE 'mktemp\s+["'\''"]?\$(\{?REPO_ROOT\}?|REPO_ROOT)/'; then
        # Skip lines with isolation-ok suppression comment
        if echo "$line" | grep -q '# isolation-ok:'; then
            continue
        fi
        echo "$file:$line_num:no-repo-source-mktemp:mktemp creates temp files inside repo source tree — use /tmp/ with a fake repo structure instead"
    fi
done < "$file"

exit 0
