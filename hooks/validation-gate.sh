#!/usr/bin/env bash
# lockpick-workflow/hooks/validation-gate.sh
# PreToolUse hook: force agents to see codebase health before starting work.
#
# This file is a thin wrapper. The hook logic lives in:
#   lockpick-workflow/hooks/lib/pre-bash-functions.sh (hook_validation_gate)
#
# Kept as a standalone wrapper so:
#   - Existing settings.json Edit/Write entries that reference this file still work
#   - run-hook.sh can call it directly for targeted invocations
#   - Task 3 dispatchers (pre-edit.sh, pre-write.sh) can source the function
#
# See lib/pre-bash-functions.sh for full documentation of the three-state model.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/pre-bash-functions.sh"

INPUT=$(cat)
hook_validation_gate "$INPUT"
exit $?
