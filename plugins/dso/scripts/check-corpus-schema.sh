#!/usr/bin/env bash
# check-corpus-schema.sh — Pre-commit hook wrapper for check-corpus-schema.py.
#
# Usage:
#   check-corpus-schema.sh [corpus_dir]
#
# If corpus_dir is not provided, defaults to the ui-reference corpus directory
# derived from CLAUDE_PLUGIN_ROOT (or from this script's location).
#
# Exits 0 if all corpus files are valid; exits 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Derive plugin root: prefer CLAUDE_PLUGIN_ROOT env var, otherwise go up from scripts/
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    _PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
    _PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

CORPUS_DIR="${1:-${_PLUGIN_ROOT}/data/ui-reference}"
VALIDATOR="${SCRIPT_DIR}/check-corpus-schema.py"

if [[ ! -f "$VALIDATOR" ]]; then
    echo "ERROR: Validator script not found: $VALIDATOR" >&2
    exit 1
fi

exec python3 "$VALIDATOR" "$CORPUS_DIR"
