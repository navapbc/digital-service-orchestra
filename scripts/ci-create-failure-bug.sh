#!/usr/bin/env bash
set -euo pipefail
# scripts/ci-create-failure-bug.sh
# Creates a tk issue when CI fails, then commits and pushes ticket files.
#
# Called by the CI workflow's create-failure-bug job when any job fails.
# Follows robustness patterns from merge-to-main.sh for the sync/commit/push cycle.
#
# Usage: scripts/ci-create-failure-bug.sh <run-id>
#   run-id: GitHub Actions run ID (from ${{ github.run_id }})
#
# Environment variables (set by CI):
#   GITHUB_SHA        - commit SHA that triggered the run
#   GITHUB_REF_NAME   - branch name
#   GITHUB_SERVER_URL - e.g. https://github.com
#   GITHUB_REPOSITORY - e.g. navapbc/lockpick-doc-to-logic
#
# Exit codes: 0=bug created+pushed, 1=error (non-fatal in CI)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TK="${TK:-$SCRIPT_DIR/tk}"

RUN_ID="${1:?Usage: ci-create-failure-bug.sh <run-id>}"

# --- Resolve repo root ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT"

# --- Verify tk is available ---
# Use $TK directly — consistent with how it is used throughout this script.
# $TK is already resolved: either the caller-supplied path or $SCRIPT_DIR/tk.
if ! command -v "$TK" &>/dev/null; then
    echo "WARNING: tk not found at $TK — CI failure tracking disabled."
    exit 0
fi

# --- Verify gh is available ---
if ! command -v gh &>/dev/null; then
    echo "ERROR: gh (GitHub CLI) not found in PATH."
    exit 1
fi

# --- Collect failed jobs ---
echo "Collecting failed jobs for run $RUN_ID..."

FAILED_JOBS_JSON=$(gh run view "$RUN_ID" --json jobs \
    --jq '[.jobs[] | select(.conclusion == "failure") | {name: .name, conclusion: .conclusion, url: .url}]' \
    2>/dev/null || echo "[]")

FAILED_JOB_NAMES=$(echo "$FAILED_JOBS_JSON" | jq -r '.[].name' 2>/dev/null || echo "")

if [ -z "$FAILED_JOB_NAMES" ]; then
    echo "No failed jobs found for run $RUN_ID. Nothing to do."
    exit 0
fi

FAILED_COUNT=$(echo "$FAILED_JOB_NAMES" | wc -l | tr -d ' ')
FAILED_LIST=$(echo "$FAILED_JOB_NAMES" | paste -sd ',' - | sed 's/,/, /g')

echo "Found $FAILED_COUNT failed job(s): $FAILED_LIST"

# --- Collect failure details ---
echo "Collecting failure details..."

# Get failed step names for each failed job
FAILED_STEP_DETAILS=""
while IFS= read -r job_name; do
    [ -z "$job_name" ] && continue
    STEP_INFO=$(gh run view "$RUN_ID" --json jobs \
        --arg jname "$job_name" \
        --jq '.jobs[] | select(.name == $jname) | .steps[] | select(.conclusion == "failure") | "  - Step: \(.name)"' \
        2>/dev/null || echo "  - (could not retrieve step details)")
    FAILED_STEP_DETAILS="${FAILED_STEP_DETAILS}
### ${job_name}
${STEP_INFO}"
done <<< "$FAILED_JOB_NAMES"

# Get truncated failed logs (last 60 lines to keep bug description manageable)
FAILED_LOGS=$(gh run view "$RUN_ID" --log-failed 2>/dev/null | tail -60 || echo "(could not retrieve logs)")

# --- Build run URL ---
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}"

# --- Build bug title ---
# Use a stable, searchable title format for deduplication
if [ "$FAILED_COUNT" -eq 1 ]; then
    BUG_TITLE="CI failure: ${FAILED_LIST} on ${GITHUB_REF_NAME:-unknown}"
else
    BUG_TITLE="CI failure: ${FAILED_COUNT} jobs on ${GITHUB_REF_NAME:-unknown}"
fi

# --- Deduplicate: search for existing open CI failure bugs for this branch ---
echo "Checking for existing CI failure bugs..."

EXISTING=""
SEARCH_TERM="CI failure"
BRANCH_PATTERN="${GITHUB_REF_NAME:-unknown}"
TICKETS_DIR="$REPO_ROOT/.tickets"
if [ -d "$TICKETS_DIR" ]; then
    for f in "$TICKETS_DIR"/*.md; do
        [ -f "$f" ] || continue
        file_status=$(awk '/^---$/{n++; next} n==1{print}' "$f" 2>/dev/null | grep -m1 '^status:' | awk '{print $2}' || echo "open")
        [ "$file_status" = "closed" ] && continue
        file_type=$(awk '/^---$/{n++; next} n==1{print}' "$f" 2>/dev/null | grep -m1 '^type:' | awk '{print $2}' || echo "task")
        [ "$file_type" = "bug" ] || continue
        # Search both title and body for CI failure + branch name
        title_line=$(grep -m1 '^# ' "$f" | sed 's/^# //' || true)
        if echo "$title_line" | grep -qiF "$SEARCH_TERM" && echo "$title_line" | grep -qiF "$BRANCH_PATTERN"; then
            EXISTING=$(basename "$f" .md)
            break
        fi
        # Fallback: check body for the branch pattern (handles title format drift)
        if echo "$title_line" | grep -qiF "$SEARCH_TERM" && grep -qi "Branch.*$BRANCH_PATTERN" "$f" 2>/dev/null; then
            EXISTING=$(basename "$f" .md)
            break
        fi
    done
fi

# --- Build failure detail block (used for both new and existing tickets) ---
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FAILURE_ENTRY="### ${TIMESTAMP}
- **Commit:** \`${GITHUB_SHA:-unknown}\`
- **Run:** [${RUN_ID}](${RUN_URL})
- **Failed jobs:** ${FAILED_LIST}
${FAILED_STEP_DETAILS}

<details><summary>Logs (last 60 lines)</summary>

\`\`\`
${FAILED_LOGS}
\`\`\`

</details>"

if [ -n "$EXISTING" ]; then
    EXISTING_ID="$EXISTING"
    echo "Found existing CI failure bug: $EXISTING_ID — appending failure details."
    "$TK" add-note "$EXISTING_ID" "---
## CI Failure — ${TIMESTAMP}
${FAILURE_ENTRY}" 2>/dev/null || true
else
    # --- Build bug description ---
    DESCRIPTION="Auto-created by CI failure detection.

## CI Run Details
- **Branch:** ${GITHUB_REF_NAME:-unknown}
- **First failure:** ${TIMESTAMP}

## Failure History

${FAILURE_ENTRY}

## Resolution Instructions

### 1. Reproduce and fix via TDD
1. Check out the failing branch: \`git checkout ${GITHUB_REF_NAME:-<branch>}\`
2. Read the CI logs: \`gh run view ${RUN_ID} --log-failed\`
3. Write a **failing unit test** that reproduces the error locally
4. Fix the code until the test passes
5. Run the full local validation: \`./scripts/validate.sh --ci\`
6. Commit the fix with the test

### 2. Investigate prevention
After fixing, investigate what changes would catch similar errors **before CI**:
- Could a unit test have caught this? If so, is the test missing or was the failure in an untested code path?
- Could a stricter lint rule or mypy config catch this class of error?
- If this was a flaky test, should it be marked with \`@pytest.mark.flaky\` or stabilized?
- Would a pre-commit hook addition catch this without significantly slowing down commits?

**Constraint:** Any prevention measure must not significantly increase the time to run \`make test-unit-only\` or commit code. Prefer fast static checks over slow runtime checks."

    echo "Creating CI failure bug..."
    ISSUE_ID=$("$TK" create "$BUG_TITLE" -t bug -p 1 2>/dev/null | grep -oE 'w[0-9]+-[a-z0-9]+' | head -1 || echo "")

    if [ -n "$ISSUE_ID" ]; then
        echo "Created CI failure bug: $ISSUE_ID"
        "$TK" add-note "$ISSUE_ID" "$DESCRIPTION" 2>/dev/null || true
    else
        echo "WARNING: tk create did not return an issue ID."
        # Search for it by title
        if [ -d "$TICKETS_DIR" ]; then
            for f in "$TICKETS_DIR"/*.md; do
                [ -f "$f" ] || continue
                title_line=$(grep -m1 '^# ' "$f" | sed 's/^# //' || true)
                if echo "$title_line" | grep -qi "$BUG_TITLE"; then
                    ISSUE_ID=$(basename "$f" .md)
                    break
                fi
            done
        fi
        if [ -n "$ISSUE_ID" ]; then
            echo "Found created bug by title search: $ISSUE_ID"
            "$TK" add-note "$ISSUE_ID" "$DESCRIPTION" 2>/dev/null || true
        fi
    fi
fi

# --- Stage, commit, and push .tickets/ ---
echo "Staging ticket files..."
git add .tickets/ 2>/dev/null || true

# Only commit if there are actual ticket changes
if git diff --cached --quiet .tickets/ 2>/dev/null; then
    echo "No ticket changes to commit."
    exit 0
fi

echo "Committing ticket changes..."
git commit -m "chore: track CI failure bug for run ${RUN_ID}

Auto-created by ci-create-failure-bug.sh
Failed jobs: ${FAILED_LIST}
Run: ${RUN_URL}" --quiet 2>/dev/null || {
    echo "WARNING: git commit failed. Ticket changes not committed."
    exit 1
}

echo "Pushing ticket changes..."
# Retry pattern from project conventions: up to 4 retries with exponential backoff
PUSH_BRANCH="${GITHUB_REF_NAME:-main}"
MAX_RETRIES=4
RETRY_DELAY=2

for attempt in $(seq 1 $((MAX_RETRIES + 1))); do
    if git push origin "HEAD:${PUSH_BRANCH}" 2>&1; then
        echo "OK: Pushed ticket changes to ${PUSH_BRANCH}."
        break
    fi

    if [ "$attempt" -gt "$MAX_RETRIES" ]; then
        echo "ERROR: Push failed after $MAX_RETRIES retries."
        exit 1
    fi

    echo "Push attempt $attempt failed. Retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    RETRY_DELAY=$((RETRY_DELAY * 2))

    # Pull before retry in case of race condition
    git pull --rebase origin "$PUSH_BRANCH" 2>/dev/null || true
done

echo "DONE: CI failure bug tracked and pushed."
