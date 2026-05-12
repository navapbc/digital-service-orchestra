#!/usr/bin/env bash
# mode-detect.sh: Output 'ci-pr' when enforcement.strategy=ci AND merge.strategy=pr
# AND git remote is non-empty; otherwise output 'local'. Always exits 0.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
CONFIG="$REPO_ROOT/.claude/dso-config.conf"

# Support DSO_CONFIG_PATH override for testing
if [[ -n "${DSO_CONFIG_PATH:-}" ]]; then
    CONFIG="$DSO_CONFIG_PATH"
fi

_enforcement=$(grep '^enforcement\.strategy=' "$CONFIG" 2>/dev/null | cut -d= -f2- || echo "")
_merge=$(grep '^merge\.strategy=' "$CONFIG" 2>/dev/null | cut -d= -f2- || echo "")
_remote=$(git remote get-url origin 2>/dev/null || echo "")

if [[ "$_enforcement" == "ci" && "$_merge" == "pr" && -n "$_remote" ]]; then
    echo "ci-pr"
else
    echo "local"
fi
