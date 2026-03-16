#!/usr/bin/env bash
# tests/hooks/test-hook-lib-no-relative-paths.sh
# Regression guard: ensures hook library function files do not use ../
# relative path navigation. All paths should use CLAUDE_PLUGIN_ROOT.
#
# Scans: post-functions.sh, pre-all-functions.sh, pre-bash-functions.sh
#
# Usage: bash tests/hooks/test-hook-lib-no-relative-paths.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_LIB_DIR="$SCRIPT_DIR/../../hooks/lib"

source "$SCRIPT_DIR/../lib/assert.sh"

echo "=== Test: zero ../ references in hook lib function files ==="

# Target files (the hook lib function files that source dispatchers set CLAUDE_PLUGIN_ROOT for)
TARGET_FILES=(
    "$HOOKS_LIB_DIR/post-functions.sh"
    "$HOOKS_LIB_DIR/pre-all-functions.sh"
    "$HOOKS_LIB_DIR/pre-bash-functions.sh"
    "$HOOKS_LIB_DIR/session-misc-functions.sh"
)

VIOLATIONS=""
VIOLATION_COUNT=0

for lib_file in "${TARGET_FILES[@]}"; do
    if [ ! -f "$lib_file" ]; then
        echo "WARNING: Expected file not found: $lib_file" >&2
        continue
    fi

    # Strip comment lines, then search for .. path navigation patterns
    # Catches both ../ (mid-path) and /.. (end-of-path, e.g. "$DIR/..")
    matches=$(grep -n '.' "$lib_file" \
        | grep -vE '^[0-9]+:\s*#' \
        | grep -E '\.\.\/' \
        || true)
    # Also catch /.. at end of a quoted string (e.g. "$DIR/..")
    more_matches=$(grep -n '.' "$lib_file" \
        | grep -vE '^[0-9]+:\s*#' \
        | grep -E '/\.\."' \
        || true)
    if [ -n "$more_matches" ]; then
        # Merge, dedup by line number
        if [ -n "$matches" ]; then
            matches=$(printf '%s\n%s' "$matches" "$more_matches" | sort -t: -k1,1n -u)
        else
            matches="$more_matches"
        fi
    fi

    if [ -n "$matches" ]; then
        VIOLATIONS="${VIOLATIONS}$(basename "$lib_file"):
${matches}
"
        VIOLATION_COUNT=$((VIOLATION_COUNT + $(echo "$matches" | wc -l | tr -d ' ')))
    fi
done

if [ "$VIOLATION_COUNT" -eq 0 ]; then
    assert_eq "no ../ references in hook lib function files" "0" "0"
else
    echo ""
    echo "VIOLATIONS FOUND ($VIOLATION_COUNT ../ references in non-comment lines):"
    echo "$VIOLATIONS"
    assert_eq "no ../ references in hook lib function files" "0" "$VIOLATION_COUNT"
fi

print_summary
