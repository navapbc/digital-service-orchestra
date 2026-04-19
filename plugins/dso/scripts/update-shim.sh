#!/usr/bin/env bash
# update-shim.sh
# Update the ${_PLUGIN_ROOT}/scripts/shim in a host project to the latest version.
#
# Usage: update-shim.sh [TARGET_REPO]
#   TARGET_REPO: path to the host project root; defaults to current git repo root
#
# Run this from the DSO plugin directory or via the dso shim:
#   bash /path/to/digital-service-orchestra/${_PLUGIN_ROOT}/scripts/update-shim.sh /path/to/host-project
#
# Exit 0 on success, 1 on error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$PLUGIN_ROOT"

# Locate the canonical template shim.
# REPO_ROOT is computed from git rev-parse relative to CWD — this assumes the script
# is run from inside the DSO plugin repo (where templates/ lives at the repo root).
# If CWD is a host project, REPO_ROOT points to the host project root (no templates/).
# The fallback resolves DIST_ROOT two levels up from PLUGIN_ROOT via dirname (i.e.,
# $repo/${CLAUDE_PLUGIN_ROOT} → $repo), which is correct when the plugin lives at $repo/${CLAUDE_PLUGIN_ROOT}.
# dirname is used instead of ../ navigation to satisfy the no-relative-paths lint rule.
TEMPLATE_SHIM="$PLUGIN_ROOT/templates/host-project/dso"

if [ ! -f "$TEMPLATE_SHIM" ]; then
    echo "Error: cannot locate template shim at $TEMPLATE_SHIM" >&2
    echo "Run this script from the DSO plugin repo root." >&2
    exit 1
fi

# Resolve target repo
if [ $# -ge 1 ]; then
    TARGET_REPO="$1"
else
    TARGET_REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        echo "Error: no TARGET_REPO argument provided and current directory is not a git repo" >&2
        exit 1
    }
fi

if [ ! -d "$TARGET_REPO" ]; then
    echo "Error: TARGET_REPO does not exist: $TARGET_REPO" >&2
    exit 1
fi

DEST="$TARGET_REPO/.claude/scripts/dso"

if [ ! -f "$DEST" ]; then
    echo "Warning: shim not found at $DEST — creating it" >&2
    mkdir -p "$TARGET_REPO/.claude/scripts/"
fi

cp "$TEMPLATE_SHIM" "$DEST"
chmod +x "$DEST"

echo "Shim updated: $DEST"
echo "Source: $TEMPLATE_SHIM"
