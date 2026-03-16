#!/usr/bin/env bash
# hooks/post-compact-review-check.sh
# SessionStart hook: fires after compaction to warn about review state integrity.
#
# After context compaction, the pre-compact-checkpoint.sh hook auto-commits
# everything via `git add -A`. If reviewer-findings.json or other review
# artifacts were in the working tree, they land in the checkpoint commit.
# This causes record-review.sh to reject --expected-hash on recovery.
#
# This hook inspects the checkpoint commit and outputs actionable guidance
# so the agent corrects the state before attempting to record any review.

HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"post-compact-review-check.sh\",\"line\":%s}\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# --- Only run when session resumes after compaction ---
INPUT=$(cat)
SOURCE=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('source',''))" 2>/dev/null || echo "")
[[ "$SOURCE" != "compact" ]] && exit 0

# --- Must be in a git repo ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# --- Check if HEAD is a pre-compaction checkpoint commit ---
HEAD_MSG=$(git log -1 --format="%s" 2>/dev/null || echo "")
if [[ "$HEAD_MSG" != *"pre-compaction"* && "$HEAD_MSG" != *"checkpoint"* ]]; then
    exit 0
fi

# --- Inspect checkpoint commit for review artifacts ---
CHECKPOINT_FILES=$(git show --name-only --format="" HEAD 2>/dev/null)
CHECKPOINT_STAT=$(git show --stat HEAD 2>/dev/null | tail -5)

CONTAINS_REVIEWER_FINDINGS=false
if echo "$CHECKPOINT_FILES" | grep -q "reviewer-findings.json"; then
    CONTAINS_REVIEWER_FINDINGS=true
fi

# --- Check whether a review was in progress before compaction ---
# Look for a review-status or review-diff file in the artifacts dir
WORKTREE_NAME=$(basename "$REPO_ROOT")
ARTIFACTS_GLOB="/tmp/workflow-plugin-*/review-diff-*.txt"
REVIEW_DIFF_EXISTS=false
# shellcheck disable=SC2086
ls $ARTIFACTS_GLOB 2>/dev/null | head -1 | grep -q . && REVIEW_DIFF_EXISTS=true

if [[ "$CONTAINS_REVIEWER_FINDINGS" == "true" ]]; then
    cat <<'WARNING'
⚠️  POST-COMPACT REVIEW INTEGRITY WARNING

The pre-compaction checkpoint commit (HEAD) contains `reviewer-findings.json`.
This file must NOT be committed — it is a review artifact verified by hash.

If you try to call record-review.sh now, --expected-hash will be REJECTED
because the staged diff includes reviewer-findings.json, which shifts the hash.

REQUIRED — do this BEFORE recording any review or making new commits:

  git show --stat HEAD          # Confirm what was committed
  git reset HEAD~1 --mixed      # Unstage (keeps all file changes)
  git add <only-the-intended-files>
  # Then record the review, then re-commit

WARNING
elif [[ "$REVIEW_DIFF_EXISTS" == "true" ]]; then
    cat <<'INFO'
ℹ️  POST-COMPACT RECOVERY: review was in progress before compaction.

A pre-compaction checkpoint commit exists at HEAD. Verify it before recording
any review result — unexpected staged files will cause --expected-hash to fail:

  git show --stat HEAD    # Confirm only intended files are in the checkpoint

If unexpected files are present: git reset HEAD~1 --mixed, restage only the
intended files, then record the review and re-commit.

INFO
fi

exit 0
