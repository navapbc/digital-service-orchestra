#!/usr/bin/env bash
# post-commit-override-cleanup.sh — removes override.token after successful commit
set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deps.sh
source "$_SCRIPT_DIR/lib/deps.sh"

ARTIFACTS_DIR=$(get_artifacts_dir)
TOKEN_FILE="$ARTIFACTS_DIR/override.token"

rm -f "$TOKEN_FILE"

exit 0
