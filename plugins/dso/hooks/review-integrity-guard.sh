#!/usr/bin/env bash
# hook-boundary: enforcement
# hooks/review-integrity-guard.sh
# PreToolUse hook (Bash matcher): blocks direct writes to review-status files.
#
# This file is a thin wrapper. The hook logic lives in:
#   hooks/lib/pre-bash-functions.sh (hook_review_integrity_guard)
#
# The review-status file must only be written by record-review.sh after a real
# code-reviewer sub-agent dispatch. Direct writes bypass review integrity.
#
# BLOCK (exit 2) — this protects a critical safety invariant.
#
# Exemptions:
#   - Commands containing record-review.sh (legitimate invocation)
#   - Writes to plan-review-status (different workflow, different file)

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/pre-bash-functions.sh"

INPUT=$(cat)
hook_review_integrity_guard "$INPUT"
exit $?
