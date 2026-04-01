#!/usr/bin/env bash
# tests/scripts/test-plugin-scripts-no-relative-paths.sh
# Verify no ../ path references remain in plugin scripts (excluding CLAUDE_PLUGIN_ROOT
# fallback lines and comments).
#
# Usage: bash tests/scripts/test-plugin-scripts-no-relative-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
PLUGIN_SCRIPTS_DIR="$DSO_PLUGIN_DIR/scripts"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-plugin-scripts-no-relative-paths.sh ==="

# ── test_no_relative_paths ──────────────────────────────────────────────────
# Grep all .sh files in scripts/ for ../ references.
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

# ── test_deps_users_use_resolve_repo_root ──────────────────────────────────
# Scripts that source deps.sh should use resolve_repo_root() instead of
# inline git rev-parse --show-toplevel for REPO_ROOT resolution.
# Exceptions:
#   - Lines inside a fallback block (e.g., "# deps.sh not found — inline fallback")
#   - Lines inside nested bash -c subshells (can't call sourced functions)
#   - Non-REPO_ROOT usages of git rev-parse (e.g., --verify, --git-dir)
#
# This guard prevents regression: once a script is migrated to resolve_repo_root(),
# new inline git rev-parse calls should not be added.

_resolve_violations=""
_resolve_actual="clean"

# Find files that source deps.sh
while IFS= read -r _deps_file; do
    # Check for git rev-parse --show-toplevel in this file
    _inline_calls=$(grep -n 'git rev-parse --show-toplevel' "$_deps_file" 2>/dev/null \
        | grep -v '^\([^:]*:[0-9]*:\)\s*#' \
        | grep -v 'inline fallback' \
        | grep -v 'bash -c' \
        || true)
    if [[ -n "$_inline_calls" ]]; then
        _resolve_violations="${_resolve_violations}${_deps_file}:
${_inline_calls}
"
    fi
done < <(grep -rl 'deps\.sh' "$PLUGIN_SCRIPTS_DIR"/*.sh "$DSO_PLUGIN_DIR"/hooks/*.sh 2>/dev/null)

if [[ -n "$_resolve_violations" ]]; then
    _vcount=$(echo "$_resolve_violations" | grep -c 'git rev-parse' || echo 0)
    _resolve_actual="found_${_vcount}_inline_git_rev_parse_calls"
    echo "resolve_repo_root() migration violations:" >&2
    echo "$_resolve_violations" >&2
    echo "These files source deps.sh — use resolve_repo_root() instead of git rev-parse --show-toplevel" >&2
fi

assert_eq "test_deps_users_use_resolve_repo_root" "clean" "$_resolve_actual"

print_summary
