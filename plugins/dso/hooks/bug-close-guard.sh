#!/usr/bin/env bash
# hooks/bug-close-guard.sh
# PreToolUse hook (Bash matcher): enforces --reason flag on bug ticket closes.
#
# This file is a thin wrapper. The hook logic lives in:
#   hooks/lib/pre-bash-functions.sh (hook_bug_close_guard)
#
# Logic:
#   1. Only fires on `ticket transition ... closed` commands
#   2. Looks up the ticket file and checks if type == bug
#   3. Non-bug tickets: always allowed (exit 0)
#   4. Bug tickets without --reason: BLOCKED (exit 2)
#   5. Bug tickets with investigation-only reason (no escalation): WARNING (exit 0 + stderr)

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/pre-bash-functions.sh"

INPUT=$(cat)
hook_bug_close_guard "$INPUT"
exit $?
