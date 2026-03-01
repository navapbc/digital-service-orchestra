#!/usr/bin/env bash
# .claude/hooks/review-gate.sh
# PreToolUse hook (Bash matcher): HARD GATE that blocks git commit if code
# review hasn't passed for the current working tree state.
#
# How it works:
#   1. Triggers on `git commit` commands
#   2. Reads the review state from record-review.sh's output
#   3. Computes the current diff hash
#   4. Blocks (exit 2) if no review, review failed, or review is stale
#
# Exempt cases:
#   - Commits with "WIP" or "wip" in the message (work-in-progress)
#   - Commits from the pre-compact-checkpoint hook (emergency saves)
#   - Merge commits (sprintend-merge.sh merges already-reviewed work)

# HARD GATE — exit 2 blocks the tool call when review is missing/stale/failed
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"review-gate.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

# Only act on Bash tool calls
TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

# Only act on git commit commands (sprintend-merge.sh is exempt — it merges
# already-reviewed commits, not new unreviewed code)
# Check first line only to avoid matching "commit" in heredoc content.
# Unanchored so "git add && git commit -m ..." is caught.
COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
FIRST_LINE=$(echo "$COMMAND" | head -1)
if ! [[ "$FIRST_LINE" =~ (^|[[:space:]|&;])git[[:space:]]+commit([[:space:]]|$) ]] && \
   ! [[ "$FIRST_LINE" =~ (^|[[:space:]|&;])git[[:space:]]+-[^[:space:]]+.*[[:space:]]commit([[:space:]]|$) ]]; then
    exit 0
fi

# Exempt: WIP commits
if [[ "$COMMAND" =~ [Ww][Ii][Pp] ]]; then
    exit 0
fi

# Exempt: git merge commands (sprintend-merge.sh merges already-reviewed work)
# NOTE: --no-edit is NOT exempt. git commit --amend --no-edit with staged code
# files would bypass review; legitimate uses (beads-only amend, merge conflict
# resolution of .beads/ files) are caught by the .beads/-only exemption below.
if [[ "$COMMAND" =~ git[[:space:]].*merge[[:space:]] ]]; then
    exit 0
fi

# Exempt: pre-compact checkpoint (emergency save)
if [[ "$COMMAND" =~ pre-compact ]] || [[ "$COMMAND" =~ checkpoint ]]; then
    exit 0
fi

# Exempt: commits that only touch .beads/ files (issue tracker metadata)
STAGED_ALL=$(git diff --cached --name-only 2>/dev/null || true)
STAGED_NON_BEADS=$(echo "$STAGED_ALL" | grep -v '^\.beads/' || true)
if [[ -n "$STAGED_ALL" && -z "$STAGED_NON_BEADS" ]]; then
    exit 0
fi

# Exempt: commits that only touch non-reviewable binary/snapshot files
# Includes: snapshot baselines, visual regression baselines, images, PDFs, DOCX
# Filters from STAGED_NON_BEADS so exemptions compose (beads + snapshots = exempt)
STAGED_NON_SNAPSHOTS=$(echo "$STAGED_NON_BEADS" \
    | grep -v -E '^app/tests/e2e/snapshots/' \
    | grep -v -E '^app/tests/unit/templates/snapshots/.*\.html$' \
    | grep -v -E '\.(png|jpg|jpeg|gif|svg|ico|webp)$' \
    | grep -v -E '\.(pdf|docx)$' \
    || true)
if [[ -n "$STAGED_ALL" && -z "$STAGED_NON_SNAPSHOTS" ]]; then
    exit 0
fi

# Exempt: commits that only touch docs/logs (markdown, session logs, design docs)
# EXCLUDES: skill files, agent guidance, hooks, and CLAUDE.md — these affect agent
# behavior and MUST be reviewed.
# Filters from STAGED_NON_SNAPSHOTS so all exemptions compose
STAGED_NON_DOCS=$(echo "$STAGED_NON_SNAPSHOTS" | grep -v -E '^(\.claude/session-logs/|\.claude/docs/|docs/)' || true)
# Re-include any "docs" files that are actually skills, hooks, or agent guidance
STAGED_AGENT_FILES=$(echo "$STAGED_ALL" | grep -E '^(\.claude/skills/|\.claude/workflows/|\.claude/hooks/|\.claude/hookify\.|lockpick-workflow/skills/|lockpick-workflow/hooks/|lockpick-workflow/docs/workflows/|CLAUDE\.md)' || true)
if [[ -n "$STAGED_ALL" && -z "$STAGED_NON_DOCS" && -z "$STAGED_AGENT_FILES" ]]; then
    exit 0
fi

# Determine worktree and state file location
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    exit 0
fi

ARTIFACTS_DIR=$(get_artifacts_dir)
REVIEW_STATE_FILE="$ARTIFACTS_DIR/review-status"

# If no review has ever been recorded, block
if [[ ! -f "$REVIEW_STATE_FILE" ]]; then
    echo "BLOCKED: No code review recorded. Use /commit (runs review automatically) or /review first." >&2
    exit 2
fi

# Read review status
REVIEW_STATUS=$(head -n 1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")

# If review failed, block
if [[ "$REVIEW_STATUS" == "failed" ]]; then
    SCORE=$(grep '^score=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    echo "BLOCKED: Code review failed (score: ${SCORE:-unknown}). Fix issues, then use /commit." >&2
    exit 2
fi

# Review passed — but is it still current? Check diff hash.
RECORDED_HASH=$(grep '^diff_hash=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

# Compute current diff hash using shared utility
CURRENT_HASH=$("$HOOK_DIR/compute-diff-hash.sh")

if [[ "$RECORDED_HASH" != "$CURRENT_HASH" ]]; then
    REVIEW_TS=$(grep '^timestamp=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    echo "BLOCKED: Review is stale (${REVIEW_TS:-unknown}; hash ${RECORDED_HASH:0:8}→${CURRENT_HASH:0:8}). Use /commit to re-run." >&2
    exit 2
fi

# Review passed and is current — allow commit
exit 0
