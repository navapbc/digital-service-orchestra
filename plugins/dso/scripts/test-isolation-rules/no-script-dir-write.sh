#!/usr/bin/env bash
set -uo pipefail
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
#   - All of the above via variable aliases derived from $SCRIPT_DIR
#     (e.g., FIXTURES_DIR="$SCRIPT_DIR/fixtures" → writes to $FIXTURES_DIR)
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

# Discover variable aliases derived from $SCRIPT_DIR.
# Matches assignments like:
#   FIXTURES_DIR="$SCRIPT_DIR/fixtures"
#   OUTPUT_DIR=$SCRIPT_DIR/output
#   SENTINEL_DIR="${SCRIPT_DIR}/sentinels"
# Captures the variable name (left-hand side of the assignment).
mapfile -t alias_vars < <(
    grep -oE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=["\x27]?\$\{?SCRIPT_DIR\}?/' "$file" 2>/dev/null \
    | grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' \
    | sed 's/^[[:space:]]*//'
)

# Build the regex alternation for $SCRIPT_DIR and all discovered aliases.
# Base: SCRIPT_DIR itself
dir_pattern='\$(\{?SCRIPT_DIR\}?)'

# Append alias patterns: $FIXTURES_DIR, ${FIXTURES_DIR}, etc.
for alias_var in "${alias_vars[@]:-}"; do
    [[ -z "$alias_var" ]] && continue
    dir_pattern="${dir_pattern}|\\\$(\{?${alias_var}\}?)"
done

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

    # Pattern 1: mkdir targeting $SCRIPT_DIR or an alias
    if echo "$line" | grep -qE "mkdir\\s+.*(${dir_pattern})(/|\")"; then
        echo "$file:$line_num:no-script-dir-write:mkdir creates directory inside \$SCRIPT_DIR (worktree) — use mktemp -d instead"
        continue
    fi

    # Pattern 2: redirect (> or >>) to $SCRIPT_DIR path or alias (quoted or unquoted)
    if echo "$line" | grep -qE ">>?\\s*\"?(${dir_pattern})/"; then
        echo "$file:$line_num:no-script-dir-write:writes file inside \$SCRIPT_DIR (worktree) — use a temp dir instead"
        continue
    fi

    # Pattern 3: cat > "$SCRIPT_DIR/..." or alias (heredoc-style write, quoted or unquoted)
    if echo "$line" | grep -qE "cat\\s*>\\s*\"?(${dir_pattern})/"; then
        echo "$file:$line_num:no-script-dir-write:writes file inside \$SCRIPT_DIR (worktree) — use a temp dir instead"
        continue
    fi

    # Pattern 4: touch targeting $SCRIPT_DIR or an alias
    if echo "$line" | grep -qE "touch\\s+.*(${dir_pattern})/"; then
        echo "$file:$line_num:no-script-dir-write:creates file inside \$SCRIPT_DIR (worktree) — use a temp dir instead"
        continue
    fi

    # Pattern 5: cp with $SCRIPT_DIR or alias as destination (quoted or unquoted)
    if echo "$line" | grep -qE "cp\\s+\\S+\\s+\"?(${dir_pattern})/"; then
        echo "$file:$line_num:no-script-dir-write:copies file into \$SCRIPT_DIR (worktree) — use a temp dir instead"
        continue
    fi
done < "$file"

exit 0
