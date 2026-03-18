#!/usr/bin/env bash
# hooks/tool-use-guard.sh
# PreToolUse hook (Bash matcher): warns when cat/head/tail/grep/rg are used
# via Bash instead of the dedicated Read/Grep tools.
#
# This file is a thin wrapper. The hook logic lives in:
#   hooks/lib/pre-bash-functions.sh (hook_tool_use_guard)
#
# WARNING ONLY (exit 0 + stderr) — agents may have legitimate reasons to use
# these commands (pipes, redirects, scripts).

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/pre-bash-functions.sh"

INPUT=$(cat)
hook_tool_use_guard "$INPUT"
exit $?
