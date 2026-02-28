#!/usr/bin/env bash
# .claude/hooks/auto-format.sh
# PostToolUse hook: auto-format .py files after Edit/Write tool calls.
#
# Replicates 'make format' (ruff import sort + ruff format) on the specific
# file just edited. Skips non-.py files and files outside app/src/ or app/tests/.
# Always exits 0 (non-blocking).
#
# Bug workaround (#20334): PostToolUse hooks with specific matchers fire for
# ALL tools, not just the matched tool. Guard on tool_name internally and
# always emit at least one byte of stdout to avoid the empty-stdout hook error.

# Guarantee exit 0 and non-empty stdout on any unexpected failure.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
trap 'exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

# Only act on Edit or Write tool calls
TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
    exit 0
fi

FILE_PATH=$(parse_json_field "$INPUT" '.tool_input.file_path')
if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Only process .py files
[[ "$FILE_PATH" == *.py ]] || exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
APP_DIR="$REPO_ROOT/app"

# Only process files under app/src/ or app/tests/
[[ "$FILE_PATH" == "$APP_DIR/src/"* || "$FILE_PATH" == "$APP_DIR/tests/"* ]] || exit 0

REL_PATH="${FILE_PATH#"$APP_DIR/"}"

# Format using ruff (import sort + format), single-file targeted.
# Suppress output — chatty messages from ruff would clutter the agent's context.
# Syntax errors mid-edit are expected (file may be incomplete); don't alarm on those.
if ! (cd "$APP_DIR" && poetry run ruff check --select I --fix "$REL_PATH" && poetry run ruff format "$REL_PATH") >/dev/null 2>&1; then
    _HOOK_HAS_OUTPUT=1
    echo "auto-format: failed on $REL_PATH — run 'make format' manually if needed"
fi

exit 0
