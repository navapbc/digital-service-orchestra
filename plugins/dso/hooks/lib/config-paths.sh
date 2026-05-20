#!/usr/bin/env bash
# hooks/lib/config-paths.sh
# Shared config path resolver for hooks and scripts.
#
# Reads host-project path config keys via read-config.sh and exports
# standardized variables with defaults matching current hardcoded values.
#
# Config resolution order (delegated entirely to read-config.sh):
#   1. WORKFLOW_CONFIG_FILE env var (exact file path — for test isolation)
#   2. .claude/dso-config.conf at git root (new canonical path)
#
# Exported variables:
#   CFG_APP_DIR              — app directory (default: app)
#   CFG_PYTHON_VENV          — Python venv path (default: app/.venv/bin/python3)
#   CFG_FORMAT_SOURCE_DIRS   — format source dirs, newline-separated (default: app/src\napp/tests)
#   CFG_VISUAL_BASELINE_PATH — visual baseline path (default: empty)
#   CFG_SRC_DIR              — source dir within app (default: src)
#   CFG_TEST_DIR             — test dir within app (default: tests)
#   CFG_UNIT_SNAPSHOT_PATH   — unit test snapshot path (default: ${CFG_APP_DIR}/tests/unit/templates/snapshots/)
#
# Usage:
#   source hooks/lib/config-paths.sh
#   echo "$CFG_APP_DIR"  # → "app" (or custom value from .claude/dso-config.conf)

# Guard: only load once
[[ "${_CONFIG_PATHS_LOADED:-}" == "1" ]] && return 0
_CONFIG_PATHS_LOADED=1

# Locate read-config.sh relative to this file (always from the plugin root, not CLAUDE_PLUGIN_ROOT)
_CONFIG_PATHS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_READ_CONFIG="$(cd "$_CONFIG_PATHS_DIR/../.." && pwd)/scripts/read-config.sh"

# --- Batch-read all config values in a single subprocess invocation ---
#
# Previously this file called _cfg_read/_cfg_read_list 6 times, each spawning a
# separate read-config.sh subprocess (which itself runs `git rev-parse`).  On cold
# disk that cost ~0.5–2.5 s per compute-diff-hash.sh invocation.
#
# Optimization: one `--batch` call reads every scalar key at once; one `--list`
# call handles the multi-value format.source_dirs key.  Total: 2 subprocesses.
#
# Batch output format (eval-safe, single-quoted values):
#   PATHS_APP_DIR='...'
#   PATHS_SRC_DIR='...'
#   PATHS_TEST_DIR='...'
#   INTERPRETER_PYTHON_VENV='...'
#   MERGE_VISUAL_BASELINE_PATH='...'
#   (FORMAT_SOURCE_DIRS is a list key — handled separately below)
#
# When no config file is found, --batch exits 0 with empty output; all variables
# remain unset and the defaults below apply.

_cfg_batch_raw=$("$_READ_CONFIG" --batch 2>/dev/null) || true
if [[ -n "$_cfg_batch_raw" ]]; then
    # eval is safe: read-config.sh --batch single-quotes every value and only
    # emits UPPER_CASE_WITH_UNDERSCORES='..' lines (no shell metacharacters).
    eval "$_cfg_batch_raw" 2>/dev/null || true
fi

# --- Read config values with defaults ---

export CFG_APP_DIR
CFG_APP_DIR="${PATHS_APP_DIR:-app}"

export CFG_PYTHON_VENV
CFG_PYTHON_VENV="${INTERPRETER_PYTHON_VENV:-app/.venv/bin/python3}"

# format.source_dirs is a multi-value (list) key — batch mode only captures the
# last occurrence.  Use a single --list subprocess to get all values newline-joined.
export CFG_FORMAT_SOURCE_DIRS
_cfg_format_dirs=$("$_READ_CONFIG" --list "format.source_dirs" 2>/dev/null) || true
CFG_FORMAT_SOURCE_DIRS="${_cfg_format_dirs:-app/src
app/tests}"
unset _cfg_format_dirs

export CFG_VISUAL_BASELINE_PATH
CFG_VISUAL_BASELINE_PATH="${MERGE_VISUAL_BASELINE_PATH:-}"

export CFG_SRC_DIR
CFG_SRC_DIR="${PATHS_SRC_DIR:-src}"

export CFG_TEST_DIR
CFG_TEST_DIR="${PATHS_TEST_DIR:-tests}"

# Clean up batch-populated intermediates so they do not leak into the environment
unset PATHS_APP_DIR PATHS_SRC_DIR PATHS_TEST_DIR INTERPRETER_PYTHON_VENV MERGE_VISUAL_BASELINE_PATH FORMAT_SOURCE_DIRS _cfg_batch_raw

# Derived: unit snapshot path uses both CFG_APP_DIR and CFG_TEST_DIR
export CFG_UNIT_SNAPSHOT_PATH
CFG_UNIT_SNAPSHOT_PATH="${CFG_APP_DIR}/${CFG_TEST_DIR}/unit/templates/snapshots/"
