#!/usr/bin/env bash
# DSO-GATE-TIER: A
# hook-boundary: enforcement
# hooks/review-gate.sh
# PreToolUse hook (Bash matcher): Layer 2 of the two-layer review gate.
#
# Blocks commands that attempt to bypass the git pre-commit review gate:
#   - --no-verify flag (bypasses pre-commit hooks)
#   - core.hooksPath override
#   - git commit-tree (low-level plumbing bypass)
#   - git update-ref
#   - Direct writes to .git/hooks/
#
# NOTE: Story 1idf (two-layer migration) removed hook_review_gate from
# pre-bash-functions.sh. Review enforcement is now two-layer:
#   - Layer 1: pre-commit-review-gate.sh (git pre-commit hook, enforces
#              allowlist + review-status + diff hash check)
#   - Layer 2: this file (PreToolUse hook, blocks bypass vectors)
#
# The logic in this file is a thin wrapper around hook_review_bypass_sentinel
# from hooks/lib/review-gate-bypass-sentinel.sh.
#
# FILES-ONLY-INSTALL ENTRY POINT: For plugin-managed installs (host projects that
# install DSO via the Claude Code plugin manager) the Layer 2 enforcement runs
# via the dispatcher chain: plugin.json PreToolUse Bash matcher →
# dispatchers/pre-bash.sh → hook_review_bypass_sentinel. This wrapper is the
# canonical entry point for host projects that install DSO as files (not as a
# Claude Code plugin) and wire individual hooks via their own settings.json —
# in that configuration their settings reference this file directly. KEEP.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/review-gate-bypass-sentinel.sh"

INPUT=$(cat)
hook_review_bypass_sentinel "$INPUT"
exit $?
