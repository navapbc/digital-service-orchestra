#!/usr/bin/env bash
# hooks/lib/config-paths.sh
# Shared config path resolver for hooks and scripts.
#
# Reads host-project path config keys via read-config.sh and exports
# standardized variables with defaults matching current hardcoded values.
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
#   echo "$CFG_APP_DIR"  # → "app" (or custom value from workflow-config.conf)

# Guard: only load once
[[ "${_CONFIG_PATHS_LOADED:-}" == "1" ]] && return 0
_CONFIG_PATHS_LOADED=1

# Locate read-config.sh relative to this file
_CONFIG_PATHS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_READ_CONFIG="${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh"

# Helper: read a config key with a default fallback
_cfg_read() {
    local key="$1"
    local default="$2"
    local val
    val=$("$_READ_CONFIG" "$key" 2>/dev/null) || true
    if [[ -n "$val" ]]; then
        echo "$val"
    else
        echo "$default"
    fi
}

# Helper: read a list config key with a default fallback (newline-separated)
_cfg_read_list() {
    local key="$1"
    local default="$2"
    local val
    val=$("$_READ_CONFIG" --list "$key" 2>/dev/null) || true
    if [[ -n "$val" ]]; then
        echo "$val"
    else
        echo "$default"
    fi
}

# --- Read config values with defaults ---

export CFG_APP_DIR
CFG_APP_DIR=$(_cfg_read "paths.app_dir" "app")

export CFG_PYTHON_VENV
CFG_PYTHON_VENV=$(_cfg_read "interpreter.python_venv" "app/.venv/bin/python3")

export CFG_FORMAT_SOURCE_DIRS
CFG_FORMAT_SOURCE_DIRS=$(_cfg_read_list "format.source_dirs" "app/src
app/tests")

export CFG_VISUAL_BASELINE_PATH
CFG_VISUAL_BASELINE_PATH=$(_cfg_read "merge.visual_baseline_path" "")

export CFG_SRC_DIR
CFG_SRC_DIR=$(_cfg_read "paths.src_dir" "src")

export CFG_TEST_DIR
CFG_TEST_DIR=$(_cfg_read "paths.test_dir" "tests")

# Derived: unit snapshot path uses both CFG_APP_DIR and CFG_TEST_DIR
export CFG_UNIT_SNAPSHOT_PATH
CFG_UNIT_SNAPSHOT_PATH="${CFG_APP_DIR}/${CFG_TEST_DIR}/unit/templates/snapshots/"
