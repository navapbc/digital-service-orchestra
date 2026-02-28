#!/bin/bash
# ci-status.sh - Token-optimized CI status checker
# Returns minimal output: "STATUS: conclusion" or waits for completion
#
# Usage:
#   ./scripts/ci-status.sh                # Check latest CI status (auto-detects worktree → main)
#   ./scripts/ci-status.sh --wait         # Wait for CI to complete (with regression check)
#   ./scripts/ci-status.sh --id           # Return just the run ID
#   ./scripts/ci-status.sh --branch main  # Check CI for a specific branch
#   ./scripts/ci-status.sh --wait --skip-regression-check  # Wait without regression check

set -e

WAIT_MODE=0
ID_ONLY=0
SKIP_REGRESSION=0
BRANCH=""

for arg in "$@"; do
    case $arg in
        --wait) WAIT_MODE=1 ;;
        --id) ID_ONLY=1 ;;
        --skip-regression-check) SKIP_REGRESSION=1 ;;
        --branch)
            # Next arg is the branch name (handled below)
            ;;
        --branch=*)
            BRANCH="${arg#--branch=}"
            ;;
        --help)
            echo "Usage: ./scripts/ci-status.sh [--wait] [--id] [--branch <name>] [--skip-regression-check]"
            echo "  --wait                    Wait for CI to complete (polls every 30s)"
            echo "  --id                      Return only the run ID"
            echo "  --branch <name>           Check CI for a specific branch (default: auto-detect)"
            echo "  --skip-regression-check   Skip baseline comparison (default: check regression)"
            echo ""
            echo "In a worktree, defaults to checking main branch CI."
            echo "Regression check compares current CI against the baseline saved by validate.sh."
            exit 0
            ;;
        *)
            # Handle --branch <value> (positional after --branch)
            if [ "${prev_arg:-}" = "--branch" ]; then
                BRANCH="$arg"
            fi
            ;;
    esac
    prev_arg="$arg"
done

# Auto-detect: in a worktree, default to main branch
if [ -z "$BRANCH" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && git rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR/..")"
    if [ -f "$REPO_ROOT/.git" ]; then
        # .git is a file → this is a worktree
        BRANCH="main"
    fi
fi

# Build the branch flag for gh commands
GH_BRANCH_FLAG=""
if [ -n "$BRANCH" ]; then
    GH_BRANCH_FLAG="--branch $BRANCH"
fi

# Get latest CI workflow run (not Deploy or other workflows)
get_status() {
    gh run list --workflow=CI $GH_BRANCH_FLAG --limit 1 --json databaseId,status,conclusion,name --jq '.[0]'
}

# Regression check: compare current CI against session baseline from validate.sh
# Returns: 0 = ok, 1 = you caused a regression, 2 = pre-existing failure
check_regression() {
    local current_conclusion="$1"
    if [ $SKIP_REGRESSION -eq 1 ]; then
        return 0
    fi

    # Find baseline file
    local worktree_name
    worktree_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")
    local baseline_file="/tmp/lockpick-test-artifacts-${worktree_name}/ci-baseline"

    if [ ! -f "$baseline_file" ]; then
        return 0  # No baseline — legacy behavior
    fi

    local baseline
    baseline=$(cat "$baseline_file")

    if [ "$current_conclusion" != "success" ]; then
        if [ "$baseline" = "success" ]; then
            echo "REGRESSION: CI was green at session start and is now failing — you caused this."
            return 1
        else
            echo "NOTE: CI was already failing at session start. Create a tracking issue if none exists."
            return 2
        fi
    fi
    return 0
}

# Get run ID only
if [ $ID_ONLY -eq 1 ]; then
    gh run list --workflow=CI $GH_BRANCH_FLAG --limit 1 --json databaseId --jq '.[0].databaseId'
    exit 0
fi

BRANCH_LABEL=""
if [ -n "$BRANCH" ]; then
    BRANCH_LABEL=" ($BRANCH)"
fi

# Wait mode: poll until complete
if [ $WAIT_MODE -eq 1 ]; then
    echo "Waiting for CI${BRANCH_LABEL} to complete..."
    while true; do
        STATUS_JSON=$(get_status)
        STATUS=$(echo "$STATUS_JSON" | jq -r '.status')
        CONCLUSION=$(echo "$STATUS_JSON" | jq -r '.conclusion')
        NAME=$(echo "$STATUS_JSON" | jq -r '.name')

        if [ "$STATUS" = "completed" ]; then
            echo "CI${BRANCH_LABEL}: $CONCLUSION ($NAME)"
            if [ "$CONCLUSION" = "success" ]; then
                exit 0
            else
                check_regression "$CONCLUSION" || true
                exit 1
            fi
        fi

        echo "  Status: $STATUS (checking again in 30s...)"
        sleep 30
    done
fi

# Default: single status check
STATUS_JSON=$(get_status)
STATUS=$(echo "$STATUS_JSON" | jq -r '.status')
CONCLUSION=$(echo "$STATUS_JSON" | jq -r '.conclusion')
NAME=$(echo "$STATUS_JSON" | jq -r '.name')
RUN_ID=$(echo "$STATUS_JSON" | jq -r '.databaseId')

if [ "$STATUS" = "completed" ]; then
    echo "CI${BRANCH_LABEL}: $CONCLUSION ($NAME) [run: $RUN_ID]"
    if [ "$CONCLUSION" = "success" ]; then
        exit 0
    else
        check_regression "$CONCLUSION" || true
        exit 1
    fi
else
    echo "CI${BRANCH_LABEL}: $STATUS ($NAME) [run: $RUN_ID]"
    exit 2  # Exit code 2 = still running
fi
