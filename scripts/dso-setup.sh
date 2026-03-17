#!/bin/sh
# scripts/dso-setup.sh
# Install the DSO shim into a host project's .claude/scripts/ directory.
#
# Usage: dso-setup.sh [TARGET_REPO [PLUGIN_ROOT]]
#   TARGET_REPO: directory to install shim into; defaults to git repo root
#   PLUGIN_ROOT: plugin directory; defaults to parent of this script's directory

set -eu

TARGET_REPO="${1:-$(git rev-parse --show-toplevel)}"
PLUGIN_ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

# Ensure TARGET_REPO is a git repository so the dso shim can locate
# workflow-config.conf via `git rev-parse --show-toplevel`.
if ! git -C "$TARGET_REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$TARGET_REPO" init -q
fi

mkdir -p "$TARGET_REPO/.claude/scripts/"
cp "$PLUGIN_ROOT/templates/host-project/dso" "$TARGET_REPO/.claude/scripts/dso"
chmod +x "$TARGET_REPO/.claude/scripts/dso"

CONFIG="$TARGET_REPO/workflow-config.conf"
if grep -q '^dso\.plugin_root=' "$CONFIG" 2>/dev/null; then
    # Update existing entry (idempotent)
    sed -i.bak "s|^dso\.plugin_root=.*|dso.plugin_root=$PLUGIN_ROOT|" "$CONFIG" && rm -f "$CONFIG.bak"
else
    printf 'dso.plugin_root=%s\n' "$PLUGIN_ROOT" >> "$CONFIG"
fi
