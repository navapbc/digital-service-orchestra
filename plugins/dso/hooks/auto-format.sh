#!/usr/bin/env bash
# .claude/hooks/auto-format.sh
# PostToolUse hook: auto-format source files after Edit/Write tool calls.
#
# By default, processes .py files under app/src/ and app/tests/.
# When WORKFLOW_CONFIG_FILE is set or CLAUDE_PLUGIN_ROOT is set and .claude/dso-config.conf is present, reads:
#   format.extensions  — list of file extensions to process (default: ['.py'])
#   format.source_dirs — directories to restrict processing to (default: app/src, app/tests)
#   commands.format    — project-wide format command (used to derive single-file command)
#
# Always exits 0 (non-blocking).
#
# Bug workaround (#20334): PostToolUse hooks with specific matchers fire for
# ALL tools, not just the matched tool. Guard on tool_name internally and
# always emit at least one byte of stdout to avoid the empty-stdout hook error.

# Guarantee exit 0 and non-empty stdout on any unexpected failure.
# _HOOK_HAS_OUTPUT=1 suppresses the {} fallback for intentional early exits.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
trap 'exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"

INPUT=$(cat)

# Only act on Edit or Write tool calls
TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
    _HOOK_HAS_OUTPUT=1; exit 0
fi

FILE_PATH=$(parse_json_field "$INPUT" '.tool_input.file_path')
if [[ -z "$FILE_PATH" ]]; then
    _HOOK_HAS_OUTPUT=1; exit 0
fi

# Skip files that do not exist (e.g. intermediate edits or paths never created)
if [[ ! -f "$FILE_PATH" ]]; then
    _HOOK_HAS_OUTPUT=1; exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { _HOOK_HAS_OUTPUT=1; exit 0; }
APP_DIR="$REPO_ROOT/app"

# ── Read config (when CLAUDE_PLUGIN_ROOT is set) ────────────────────────────
# format.extensions — list of extensions to process (fallback: .py)
# format.source_dirs — directories to restrict to (fallback: app/src, app/tests)
# commands.format   — project-wide format command (used to derive single-file command)

CONFIG_FILE=""
if [[ -n "${WORKFLOW_CONFIG_FILE:-}" && -f "${WORKFLOW_CONFIG_FILE}" ]]; then
    CONFIG_FILE="${WORKFLOW_CONFIG_FILE}"
elif [[ -n "${CLAUDE_PLUGIN_ROOT}" ]]; then
    if [[ -f "${CLAUDE_PLUGIN_ROOT}/.claude/dso-config.conf" ]]; then
        CONFIG_FILE="${CLAUDE_PLUGIN_ROOT}/.claude/dso-config.conf"
    fi
fi

# Read format.extensions list from config via read-config.sh --list
CONFIGURED_EXTS=()
if [[ -n "$CONFIG_FILE" ]]; then
    _RAW_EXTS=$(bash "$SCRIPTS_DIR/read-config.sh" --list format.extensions "$CONFIG_FILE" 2>/dev/null) || true
    if [[ -n "$_RAW_EXTS" ]]; then
        while IFS= read -r ext; do
            CONFIGURED_EXTS+=("$ext")
        done <<< "$_RAW_EXTS"
    fi
fi

# Fallback to .py when no config or key absent
if [[ ${#CONFIGURED_EXTS[@]} -eq 0 ]]; then
    CONFIGURED_EXTS=('.py')
fi

# Read format.source_dirs from config via read-config.sh --list
CONFIGURED_DIRS=()
if [[ -n "$CONFIG_FILE" ]]; then
    _RAW_DIRS=$(bash "$SCRIPTS_DIR/read-config.sh" --list format.source_dirs "$CONFIG_FILE" 2>/dev/null) || true
    if [[ -n "$_RAW_DIRS" ]]; then
        while IFS= read -r dir; do
            CONFIGURED_DIRS+=("$dir")
        done <<< "$_RAW_DIRS"
    fi
fi

# ── Check extension ──────────────────────────────────────────────────────────
_EXT_MATCHED=0
for ext in "${CONFIGURED_EXTS[@]}"; do
    if [[ "$FILE_PATH" == *"$ext" ]]; then
        _EXT_MATCHED=1
        break
    fi
done
if [[ "$_EXT_MATCHED" -eq 0 ]]; then
    _HOOK_HAS_OUTPUT=1; exit 0
fi

# ── Check source directory restriction ──────────────────────────────────────
if [[ ${#CONFIGURED_DIRS[@]} -gt 0 ]]; then
    # Config-provided source dirs (relative to REPO_ROOT or absolute)
    _DIR_MATCHED=0
    for src_dir in "${CONFIGURED_DIRS[@]}"; do
        # Resolve relative paths against REPO_ROOT
        if [[ "$src_dir" == /* ]]; then
            _abs_dir="$src_dir"
        else
            _abs_dir="$REPO_ROOT/$src_dir"
        fi
        if [[ "$FILE_PATH" == "$_abs_dir/"* ]]; then
            _DIR_MATCHED=1
            break
        fi
    done
    if [[ "$_DIR_MATCHED" -eq 0 ]]; then
        _HOOK_HAS_OUTPUT=1; exit 0
    fi
else
    # Default: only process files under app/src/ or app/tests/
    if [[ "$FILE_PATH" != "$APP_DIR/src/"* && "$FILE_PATH" != "$APP_DIR/tests/"* ]]; then
        _HOOK_HAS_OUTPUT=1; exit 0
    fi
fi

# Derive relative path from APP_DIR for .py files (legacy ruff invocation)
REL_PATH="${FILE_PATH#"$APP_DIR/"}"

# ── Format the file ──────────────────────────────────────────────────────────
# Read commands.format from config and use it for all matched extensions.
# If commands.format is not configured and the file is .py, fall back to
# `poetry run ruff` for backward compatibility (if available).
#
# Suppress output — chatty messages would clutter the agent's context.
# Syntax errors mid-edit are expected (file may be incomplete); don't alarm on those.

# Read commands.format from config (applies to all extension types including .py).
# Try read-config.sh first (supports YAML and conf formats); fall back to direct grep
# on the conf file so tests with minimal plugin roots still work.
FORMAT_CMD=""
if [[ -n "$CONFIG_FILE" ]]; then
    if [[ -x "$SCRIPTS_DIR/read-config.sh" ]]; then
        FORMAT_CMD=$("$SCRIPTS_DIR/read-config.sh" commands.format "$CONFIG_FILE" 2>/dev/null || echo '')
    else
        # Fallback: direct grep for flat KEY=VALUE conf files
        FORMAT_CMD=$(grep '^commands\.format=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true)
    fi
fi

if [[ -n "$FORMAT_CMD" ]]; then
    # Config-driven format command: use for all matched extensions
    if ! eval "$FORMAT_CMD" >/dev/null 2>&1; then
        _HOOK_HAS_OUTPUT=1
        echo "auto-format: failed on $FILE_PATH — run format manually if needed"
    fi
elif [[ "$FILE_PATH" == *.py ]]; then
    # No commands.format configured: fall back to poetry run ruff for .py files
    # (backward compatibility for projects that have not yet set commands.format)
    if ! (cd "$APP_DIR" && poetry run ruff check --select I --fix "$REL_PATH" && poetry run ruff format "$REL_PATH") >/dev/null 2>&1; then
        _HOOK_HAS_OUTPUT=1
        echo "auto-format: failed on $REL_PATH — run 'make format' manually if needed"
    fi
else
    # No format command configured for this extension — emit a warning
    echo "[DSO WARN] commands.format not configured — skipping format for ${FILE_PATH##*.} files."
    _HOOK_HAS_OUTPUT=1
fi

exit 0
