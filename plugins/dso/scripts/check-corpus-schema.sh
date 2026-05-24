#!/usr/bin/env bash
# check-corpus-schema.sh — Pre-commit hook wrapper for check-corpus-schema.py.
#
# Usage:
#   check-corpus-schema.sh [corpus_dir_or_file]
#
# If no argument is provided, defaults to the ui-reference corpus directory
# derived from CLAUDE_PLUGIN_ROOT (or from this script's location).
#
# When a single YAML file is passed, validates that file using the _schema.yaml
# from the nearest parent directory that contains one.
#
# Exits 0 if all corpus files are valid; exits 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Derive plugin root. Candidates are tested in order; first one whose
# data/ui-reference subdirectory exists is selected.
#
# Worktree note: CLAUDE_PLUGIN_ROOT is set in the shell environment and may
# point to the main-repo plugin rather than the worktree plugin. We verify the
# corpus actually exists before trusting any candidate.
#
# Candidate order:
#   1. CLAUDE_PLUGIN_ROOT env var (when corpus exists there)
#   2. SCRIPT_DIR/.. — the plugin root relative to this script's location
#      (works correctly when CWD or $0 places SCRIPT_DIR inside the worktree)
#   3. CLAUDE_PLUGIN_ROOT env var (fallback, even if corpus absent — caller override)
_SCRIPT_PARENT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] && [[ -d "${CLAUDE_PLUGIN_ROOT}/data/ui-reference" ]]; then
    _PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
elif [[ -d "${_SCRIPT_PARENT}/data/ui-reference" ]]; then
    _PLUGIN_ROOT="$_SCRIPT_PARENT"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    _PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
    _PLUGIN_ROOT="$_SCRIPT_PARENT"
fi

TARGET="${1:-${_PLUGIN_ROOT}/data/ui-reference}"
VALIDATOR="${SCRIPT_DIR}/check-corpus-schema.py"

if [[ ! -f "$VALIDATOR" ]]; then
    echo "ERROR: Validator script not found: $VALIDATOR" >&2
    exit 1
fi

# If the argument is a file, find the nearest _schema.yaml in the parent hierarchy
# and run the validator on the containing directory (filtering to just that file
# would require code changes; instead we run against the file's parent directory).
if [[ -f "$TARGET" ]]; then
    CORPUS_DIR="$(dirname "$TARGET")"
    # Walk up to find _schema.yaml if not in immediate parent
    SCHEMA_DIR="$CORPUS_DIR"
    while [[ "$SCHEMA_DIR" != "/" ]]; do
        if [[ -f "$SCHEMA_DIR/_schema.yaml" ]]; then
            break
        fi
        SCHEMA_DIR="$(dirname "$SCHEMA_DIR")"
    done
    if [[ -f "$SCHEMA_DIR/_schema.yaml" ]]; then
        exec python3 "$VALIDATOR" "$CORPUS_DIR" --schema "$SCHEMA_DIR/_schema.yaml"
    else
        exec python3 "$VALIDATOR" "$CORPUS_DIR"
    fi
else
    exec python3 "$VALIDATOR" "$TARGET"
fi
