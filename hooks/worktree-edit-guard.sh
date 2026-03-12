#!/usr/bin/env bash
# lockpick-workflow/hooks/worktree-edit-guard.sh
# PreToolUse hook: block Edit/Write/Bash(mkdir) calls targeting main repo from a worktree
#
# This file is a thin wrapper. The hook logic lives in:
#   lockpick-workflow/hooks/lib/pre-bash-functions.sh (hook_worktree_edit_guard)
#
# Enforces CLAUDE.md rule 11:
#   "Never edit main repo files from a worktree session"
#
# Note: hook_validation_gate() and hook_worktree_edit_guard() are also reused
# by Task 3's Edit/Write dispatchers (pre-edit.sh, pre-write.sh).

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/pre-bash-functions.sh"

INPUT=$(cat)
hook_worktree_edit_guard "$INPUT"
exit $?
