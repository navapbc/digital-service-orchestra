#!/usr/bin/env bash
# .claude/hooks/review-stop-check.sh
# Stop hook: when Claude finishes responding, check whether there are
# uncommitted code changes that haven't been reviewed.
#
# This catches the case where an agent writes code and claims "done" without
# running /dso:review or committing.
#
# This is a SOFT GATE (warning). It outputs a reminder but does not block.
#
# Conditions for warning:
#   1. There are uncommitted changes to tracked files
#   2. No review state file exists, OR the review is stale
#
# Conditions for silence:
#   - Working tree is clean (nothing to review)
#   - Review is current and passed

# Never surface errors — log and exit cleanly
HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"review-stop-check.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library (provides get_artifacts_dir)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# Determine repo root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    exit 0
fi

# Check for uncommitted changes
CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null || true)
STAGED_FILES=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null || true)
UNTRACKED_FILES=$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null || true)

# If no code changes, nothing to review
if [[ -z "$CHANGED_FILES" ]] && [[ -z "$STAGED_FILES" ]] && [[ -z "$UNTRACKED_FILES" ]]; then
    exit 0
fi

# Early exit: if review is current and passed, skip the REMINDER entirely.
# This avoids noisy output on every Stop when the agent has already reviewed.
ARTIFACTS_DIR=$(get_artifacts_dir)
REVIEW_STATE_FILE="$ARTIFACTS_DIR/review-status"

if [[ -f "$REVIEW_STATE_FILE" ]]; then
    REVIEW_STATUS=$(head -n 1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")
    if [[ "$REVIEW_STATUS" == "passed" ]]; then
        RECORDED_HASH=$(grep '^diff_hash=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
        CURRENT_HASH=$("$HOOK_DIR/compute-diff-hash.sh")
        if [[ "$RECORDED_HASH" == "$CURRENT_HASH" ]]; then
            # Review is current and passed — exit silently
            exit 0
        fi
    fi
fi

# Count changed files for the warning message
TOTAL_CHANGED=$(
    {
        echo "$CHANGED_FILES"
        echo "$STAGED_FILES"
        echo "$UNTRACKED_FILES"
    } | sort -u | grep -cv '^$'
)

# Case 1: No review recorded
if [[ ! -f "$REVIEW_STATE_FILE" ]]; then
    echo "# REMINDER: Uncommitted changes not reviewed"
    echo ""
    echo "There are **${TOTAL_CHANGED} changed file(s)** that have not been code-reviewed."
    echo ""
    echo "Before completing this task, follow the Task Completion Workflow:"
    echo "  1. Run \`/dso:review\` to review your changes"
    echo "  2. Fix any issues (scores must be >= 4)"
    echo "  3. Commit and push"
    echo "  4. Wait for CI to pass"
    echo ""
    exit 0
fi

# Case 2: Review failed
REVIEW_STATUS=$(head -n 1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")
if [[ "$REVIEW_STATUS" == "failed" ]]; then
    echo "# REMINDER: Last review did not pass"
    echo ""
    echo "There are **${TOTAL_CHANGED} changed file(s)** and the last review **failed**."
    echo ""
    echo "Fix review issues, re-run \`/dso:review\`, then commit."
    echo ""
    exit 0
fi

# Case 3: Review passed but stale (hash mismatch already checked in early exit)
echo "# REMINDER: Code changed since last review"
echo ""
echo "There are **${TOTAL_CHANGED} changed file(s)** modified after the last review."
echo ""
echo "Re-run \`/dso:review\` before committing."
echo ""
exit 0
