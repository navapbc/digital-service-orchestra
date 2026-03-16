#!/usr/bin/env bash
# hooks/commit-failure-tracker.sh
# PreToolUse hook (Bash matcher): at git commit time, warn if validation
# failures exist without corresponding open tracking issues.
#
# This file is a thin wrapper. The hook logic lives in:
#   hooks/lib/pre-bash-functions.sh (hook_commit_failure_tracker)
#
# NEVER BLOCKS — warnings only (exit 0).

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/pre-bash-functions.sh"

INPUT=$(cat)
hook_commit_failure_tracker "$INPUT"
exit $?
