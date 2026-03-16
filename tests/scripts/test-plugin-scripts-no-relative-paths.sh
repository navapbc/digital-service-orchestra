#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-plugin-scripts-no-relative-paths.sh
# Verify no ../ path references remain in plugin scripts (excluding CLAUDE_PLUGIN_ROOT
# fallback lines and comments).
#
# Usage: bash lockpick-workflow/tests/scripts/test-plugin-scripts-no-relative-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
PLUGIN_SCRIPTS_DIR="$PLUGIN_ROOT/scripts"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-plugin-scripts-no-relative-paths.sh ==="

# ── test_no_relative_paths ──────────────────────────────────────────────────
# Grep all .sh files in lockpick-workflow/scripts/ for ../ references.
# Exclude:
#   - Lines containing CLAUDE_PLUGIN_ROOT (fallback pattern)
#   - Comment-only lines (leading # after optional whitespace)
#   - Lines inside string literals that aren't path references (e.g. 'src/.../base.py')

matches=""
if matches=$(grep -rn '\.\.\/' "$PLUGIN_SCRIPTS_DIR" --include='*.sh' \
    | grep -v 'CLAUDE_PLUGIN_ROOT' \
    | grep -v '^\([^:]*:[0-9]*:\)\s*#' \
    | grep -v 'src/\.\.\./' \
    2>/dev/null); then
    match_count=$(echo "$matches" | wc -l | tr -d ' ')
    actual="found_${match_count}_violations"
    if [[ -n "$matches" ]]; then
        echo "Violations found:" >&2
        echo "$matches" >&2
    fi
else
    match_count=0
    actual="clean"
fi

assert_eq "test_no_relative_paths_in_plugin_scripts" "clean" "$actual"

# ── test_scripts_with_repo_root_use_git_rev_parse ───────────────────────────
# Scripts that set REPO_ROOT should use $(git rev-parse --show-toplevel)
# rather than ../ relative navigation.
# This is a softer check — we just verify that scripts using REPO_ROOT
# don't derive it from ../ patterns.

repo_root_violations=""
if repo_root_violations=$(grep -rn 'REPO_ROOT=.*\.\.\/' "$PLUGIN_SCRIPTS_DIR" --include='*.sh' \
    | grep -v 'CLAUDE_PLUGIN_ROOT' \
    | grep -v '^\([^:]*:[0-9]*:\)\s*#' \
    2>/dev/null); then
    violation_count=$(echo "$repo_root_violations" | wc -l | tr -d ' ')
    actual2="found_${violation_count}_repo_root_violations"
    if [[ -n "$repo_root_violations" ]]; then
        echo "REPO_ROOT ../ violations:" >&2
        echo "$repo_root_violations" >&2
    fi
else
    actual2="clean"
fi

assert_eq "test_repo_root_no_relative_derivation" "clean" "$actual2"

print_summary
