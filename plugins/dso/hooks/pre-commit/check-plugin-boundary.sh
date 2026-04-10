#!/usr/bin/env bash
# plugins/dso/hooks/pre-commit/check-plugin-boundary.sh
# Enforces the plugin boundary: blocks commits that add files to plugins/dso/
# that are outside the positive-enumeration allowlist.
#
# Allowlist location: same directory as this script — plugin-boundary-allowlist.conf
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
    ALLOWLIST_FILE="$SCRIPT_DIR/plugin-boundary-allowlist.conf"
fi

# Discover staged additions to plugins/dso/
mapfile -t staged_files < <(git diff --cached --name-only --diff-filter=A 2>/dev/null | grep '^plugins/dso/')

# Fast path: no additions to plugins/dso/
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

# Check each staged file against allowlist patterns
violations=()
for staged_path in "${staged_files[@]}"; do
    # Strip the "plugins/dso/" prefix to get relative path within the plugin
    relative_path="${staged_path#plugins/dso/}"

    matched=0
    for pattern in "${allowlist_patterns[@]}"; do
        case "$relative_path" in
            $pattern)
                matched=1
                break
                ;;
        esac
    done

    if [[ "$matched" -eq 0 ]]; then
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
