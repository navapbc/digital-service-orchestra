#!/usr/bin/env bash
set -uo pipefail
# Rule: no-temp-without-cleanup
# Detects mktemp usage in bash/shell test files without a corresponding
# trap ... EXIT cleanup handler.
#
# Rule contract:
#   - Receives a file path as $1
#   - Outputs violations as file:line:no-temp-without-cleanup:message to stdout
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

# Check if file contains mktemp usage
if ! grep -qE '\bmktemp\b' "$file" 2>/dev/null; then
    # No mktemp usage — nothing to check
    exit 0
fi

# Check if file contains a trap ... EXIT cleanup handler
# REVIEW-DEFENSE: This is a file-level check — if ANY trap EXIT exists, the file passes.
# Multiple mktemp calls with only one trap is a design limitation, not a bug. The file-level
# check catches the common case (mktemp with zero cleanup). Per-call trap association would
# require control-flow analysis beyond what a grep-based rule can reliably provide.
if grep -qE 'trap\s+.*\s+EXIT' "$file" 2>/dev/null; then
    # Has trap EXIT — cleanup is present
    exit 0
fi

# File has mktemp but no trap EXIT — report each mktemp line as a violation
# Lines with "# isolation-ok:" are suppressed (used for test fixtures).
line_num=0
while IFS= read -r line; do
    (( line_num++ ))
    if echo "$line" | grep -qE '\bmktemp\b'; then
        # Skip lines with isolation-ok suppression comment
        if echo "$line" | grep -q '# isolation-ok:'; then
            continue
        fi
        echo "$file:$line_num:no-temp-without-cleanup:mktemp used without trap ... EXIT cleanup"
    fi
done < "$file"

exit 0
