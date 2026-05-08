#!/usr/bin/env bash
# prepare-commit-msg-override-audit.sh — appends Override-Reason trailer when override token is present
set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deps.sh
source "$_SCRIPT_DIR/lib/deps.sh"

ARTIFACTS_DIR=$(get_artifacts_dir)
TOKEN_FILE="$ARTIFACTS_DIR/override.token"

if [[ ! -f "$TOKEN_FILE" ]]; then
  exit 0
fi

_reason=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['reason'])" "$TOKEN_FILE" 2>/dev/null)

if [[ -z "${_reason:-}" ]]; then
  exit 0
fi

echo "Override-Reason: $_reason" >> "$1"

exit 0
