#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../..}"
_PLUGIN_GIT_PATH="${_PLUGIN_ROOT#$(cd "$_PLUGIN_ROOT" && git rev-parse --show-toplevel)/}"
# check-plugin-boundary.sh
# Enforces the plugin boundary: blocks commits that add files to ${CLAUDE_PLUGIN_ROOT}/
# that are outside the positive-enumeration allowlist.
#
# Allowlist location: $REPO_ROOT/.claude/hooks/pre-commit/plugin-boundary-allowlist.conf
#   (or override via PLUGIN_BOUNDARY_ALLOWLIST env var)
# Fail-open: if allowlist missing/unreadable, exit 0 with warning
# Registration: pre-commit framework (see .pre-commit-config.yaml)
#
# Usage: called automatically by pre-commit framework
# Environment override: PLUGIN_BOUNDARY_ALLOWLIST=<path> overrides default allowlist path

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve allowlist path: env var override or default
if [[ -n "${PLUGIN_BOUNDARY_ALLOWLIST:-}" ]]; then
    ALLOWLIST_FILE="$PLUGIN_BOUNDARY_ALLOWLIST"
else
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    ALLOWLIST_FILE="$REPO_ROOT/.claude/hooks/pre-commit/plugin-boundary-allowlist.conf"
fi

# Discover staged additions to ${CLAUDE_PLUGIN_ROOT}/
mapfile -t staged_files < <(git diff --cached --name-only --diff-filter=A 2>/dev/null | grep "^${_PLUGIN_GIT_PATH}/")

# Fast path: no additions to ${CLAUDE_PLUGIN_ROOT}/
if [[ ${#staged_files[@]} -eq 0 ]]; then
    exit 0
fi

# Fail-open: if allowlist missing or unreadable, warn and exit 0
if [[ ! -f "$ALLOWLIST_FILE" ]] || [[ ! -r "$ALLOWLIST_FILE" ]]; then
    echo "WARNING: plugin-boundary-allowlist.conf not found or unreadable at $ALLOWLIST_FILE — skipping plugin boundary check (fail-open)" >&2
    exit 0
fi

# Read allowlist patterns (skip blank lines and comments)
allowlist_patterns=()
while IFS= read -r line; do
    # Skip blank lines and comment lines
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    allowlist_patterns+=("$line")
done < "$ALLOWLIST_FILE"

# Check each staged file against allowlist patterns using Python fnmatch.
# fnmatch treats '*' as not matching '/' — so 'docs/*.md' correctly allows
# 'docs/INSTALL.md' but blocks 'docs/designs/test.md'. Bash 'case' glob does
# not have this property (*  matches any character including '/').
# '**' patterns continue to work because fnmatch.fnmatch() treats '**' as
# matching anything (equivalent to '.*' in regex, including '/').
_match_path_against_allowlist() {
    local _rel_path="$1"
    shift
    # Custom glob_to_regex matching: '*' matches any char except '/', '**' matches
    # any char including '/'. This prevents docs/*.md from matching docs/designs/test.md.
    # One python3 subprocess is spawned per staged file (patterns streamed via stdin).
    # Path passed via env var (_MATCH_PATH) to avoid shell injection.
    printf '%s\n' "$@" | _MATCH_PATH="$_rel_path" python3 -c '
import re, sys, os

def glob_to_regex(pattern):
    """Convert glob pattern to regex. * does not match /, ** matches anything."""
    parts = pattern.split("**")
    escaped = [re.escape(p).replace(r"\*", "[^/]*").replace(r"\?", "[^/]") for p in parts]
    return "^" + ".*".join(escaped) + "$"

path = os.environ.get("_MATCH_PATH", "")
for line in sys.stdin:
    pattern = line.rstrip("\n")
    if not pattern:
        continue
    try:
        if re.fullmatch(glob_to_regex(pattern), path):
            sys.exit(0)
    except re.error:
        pass
sys.exit(1)
' 2>/dev/null
}

violations=()
for staged_path in "${staged_files[@]}"; do
    # Strip the "${CLAUDE_PLUGIN_ROOT}/" prefix to get relative path within the plugin
    relative_path="${staged_path#${_PLUGIN_GIT_PATH}/}"

    if ! _match_path_against_allowlist "$relative_path" "${allowlist_patterns[@]}"; then
        violations+=("$staged_path")
    fi
done

# Report violations and exit non-zero
if [[ ${#violations[@]} -gt 0 ]]; then
    echo "ERROR: Plugin boundary violation — the following staged files are not permitted by plugin-boundary-allowlist.conf:" >&2
    for v in "${violations[@]}"; do
        echo "  $v" >&2
    done
    echo "" >&2
    echo "To permit a new path, add a glob pattern to plugin-boundary-allowlist.conf at:" >&2
    echo "  $ALLOWLIST_FILE" >&2
    exit 1
fi

exit 0
