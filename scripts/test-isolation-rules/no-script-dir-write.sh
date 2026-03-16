#!/usr/bin/env bash
# Rule: no-script-dir-write
# Detects file-creation operations targeting $SCRIPT_DIR (the test file's own
# directory inside the worktree). Tests should create files in mktemp dirs, not
# alongside the test script.
#
# Detected patterns:
#   - mkdir ... $SCRIPT_DIR/...
#   - Redirect (> or >>) to $SCRIPT_DIR/... paths
#   - touch $SCRIPT_DIR/...
#   - cp ... $SCRIPT_DIR/... (as destination)
#
# Not detected (by design — low signal):
#   - $REPO_ROOT writes (too many legitimate reads/copies from repo)
#
# Rule contract:
#   - Receives a file path as $1
#   - Outputs violations as file:line:no-script-dir-write:message to stdout
#   - Exits 0 (violations reported via stdout, not exit code)
#
# Only checks .sh and .bash files (skips other extensions).
# Suppression: lines with "# isolation-ok:" are skipped.

set -uo pipefail

file="$1"

# Only check bash/shell test files (match on basename, not full path)
basename_file="$(basename "$file")"
case "$basename_file" in
    test*.sh|test*.bash) ;;
    *) exit 0 ;;
esac

# Quick check: does the file reference SCRIPT_DIR at all?
if ! grep -q 'SCRIPT_DIR' "$file" 2>/dev/null; then
    exit 0
fi

line_num=0
while IFS= read -r line; do
    (( line_num++ ))

    # Skip empty lines and comments
    stripped="${line##*([[:space:]])}"
    [[ -z "$stripped" ]] && continue
    [[ "$stripped" == \#* ]] && continue

    # Skip suppressed lines
    if echo "$line" | grep -q '# isolation-ok:'; then
        continue
    fi

    # Pattern 1: mkdir targeting $SCRIPT_DIR
    if echo "$line" | grep -qE 'mkdir\s+.*\$(\{?SCRIPT_DIR\}?)(/|")'; then
        echo "$file:$line_num:no-script-dir-write:mkdir creates directory inside \$SCRIPT_DIR (worktree) — use mktemp -d instead"
        continue
    fi

    # Pattern 2: redirect (> or >>) to $SCRIPT_DIR path (quoted or unquoted)
    if echo "$line" | grep -qE '>>?\s*"?\$(\{?SCRIPT_DIR\}?)/'; then
        echo "$file:$line_num:no-script-dir-write:writes file inside \$SCRIPT_DIR (worktree) — use a temp dir instead"
        continue
    fi

    # Pattern 3: cat > "$SCRIPT_DIR/..." (heredoc-style write, quoted or unquoted)
    if echo "$line" | grep -qE 'cat\s*>\s*"?\$(\{?SCRIPT_DIR\}?)/'; then
        echo "$file:$line_num:no-script-dir-write:writes file inside \$SCRIPT_DIR (worktree) — use a temp dir instead"
        continue
    fi

    # Pattern 4: touch targeting $SCRIPT_DIR
    if echo "$line" | grep -qE 'touch\s+.*\$(\{?SCRIPT_DIR\}?)/'; then
        echo "$file:$line_num:no-script-dir-write:creates file inside \$SCRIPT_DIR (worktree) — use a temp dir instead"
        continue
    fi

    # Pattern 5: cp with $SCRIPT_DIR as destination (quoted or unquoted)
    if echo "$line" | grep -qE 'cp\s+\S+\s+"?\$(\{?SCRIPT_DIR\}?)/'; then
        echo "$file:$line_num:no-script-dir-write:copies file into \$SCRIPT_DIR (worktree) — use a temp dir instead"
        continue
    fi
done < "$file"

exit 0
