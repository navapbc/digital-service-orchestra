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
#
# --wait uses adaptive polling calibrated from ci.yml timeouts:
#
#   Phase 0 | DEAD ZONE    | 0 – 45s      | skip (runner startup, no signal possible)
#   Phase 1 | FAST-FAIL    | 45s – 3min   | 30s interval (fast-gate / security-scan)
#   Phase 2 | TEST WINDOW  | 3min – 15min | 60s interval (unit / integration / mypy)
#   Phase 3 | E2E WINDOW   | 15min – ceil | 90s interval (E2E / multiworker)
#   Phase 4 | CEILING      | > ceil       | hard timeout error
#
# Polling starts from the run's startedAt, not from script invocation time.
# This means --wait called mid-run immediately jumps to the correct phase.
# On any failure, fast-gate status is checked first; if fast-gate failed,
# the script exits immediately without waiting for downstream job draining.

set -e

WAIT_MODE=0
ID_ONLY=0
SKIP_REGRESSION=0
BRANCH=""
CHECK_JOBS_RUN_ID=""

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
        --check-jobs=*)
            CHECK_JOBS_RUN_ID="${arg#--check-jobs=}"
            ;;
        --help)
            echo "Usage: ./scripts/ci-status.sh [--wait] [--id] [--branch <name>] [--skip-regression-check]"
            echo "  --wait                    Wait for CI to complete (adaptive polling)"
            echo "  --id                      Return only the run ID"
            echo "  --branch <name>           Check CI for a specific branch (default: auto-detect)"
            echo "  --skip-regression-check   Skip baseline comparison (default: check regression)"
            echo "  --check-jobs=<run-id>     Print one line per job: '<conclusion> <name>'"
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

# --check-jobs: print one line per job for a given run ID
if [ -n "$CHECK_JOBS_RUN_ID" ]; then
    gh run view "$CHECK_JOBS_RUN_ID" --json jobs --jq '.jobs[] | "\(.conclusion) \(.name)"'
    exit 0
fi

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

# Get latest CI workflow run — includes startedAt/createdAt for elapsed calculation
get_status() {
    gh run list --workflow=CI $GH_BRANCH_FLAG --limit 1 \
        --json databaseId,status,conclusion,name,startedAt,createdAt \
        --jq '.[0]'
}

# Convert ISO-8601 timestamp to epoch seconds (cross-platform: GNU and macOS date).
# Returns empty string on parse failure so callers can distinguish failure from epoch 0.
to_epoch() {
    local ts="$1"
    # Strip sub-seconds and trailing Z for compatibility
    local ts_clean="${ts%%.*}"
    ts_clean="${ts_clean%Z}"
    ts_clean="${ts_clean%+00:00}"
    local result=""
    if date --version >/dev/null 2>&1; then
        # GNU/Linux
        result=$(date -d "${ts_clean}Z" +%s 2>/dev/null || true)
    else
        # macOS
        result=$(date -jf "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null || true)
    fi
    echo "$result"
}

# Parse phase ceilings from ci.yml timeout-minutes values.
# Sets globals: DEAD_ZONE_SEC, FAST_FAIL_SEC, TEST_CEIL_SEC, CEILING_SEC
parse_phase_ceilings() {
    local yaml=""
    # Locate ci.yml relative to this script (works from worktree or main repo)
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    local candidate
    for candidate in \
        "$script_dir/../../.github/workflows/ci.yml" \
        "$script_dir/../../../.github/workflows/ci.yml"
    do
        if [ -f "$candidate" ]; then
            yaml="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
            break
        fi
    done

    if [ -z "$yaml" ]; then
        # Fallback: hardcoded values matching current ci.yml
        DEAD_ZONE_SEC=45
        FAST_FAIL_SEC=180    # 3 min
        TEST_CEIL_SEC=900    # 15 min (unit test timeout)
        CEILING_SEC=1320     # 22 min (E2E 20min + 2min buffer)
        return
    fi

    # Extract all timeout-minutes values
    local all_timeouts
    all_timeouts=$(grep 'timeout-minutes:' "$yaml" | awk '{print $2}' | grep -E '^[0-9]+$')

    local max_timeout
    max_timeout=$(echo "$all_timeouts" | sort -rn | head -1)

    # security-scan has the smallest no-dep job timeout (5min) → fast-fail boundary
    # unit test job (15min) → test window ceiling
    # E2E (20min) → the max_timeout that sets the absolute ceiling
    DEAD_ZONE_SEC=45
    FAST_FAIL_SEC=180    # 3 min: all no-dep jobs (fast-gate ~1-2min, security-scan ~1-2min)
    TEST_CEIL_SEC=900    # 15 min: unit/integration timeouts from ci.yml
    CEILING_SEC=$(( max_timeout * 60 + 120 ))  # max timeout + 2min runner teardown buffer
}

# Return the sleep interval (seconds) appropriate for the elapsed time into this run.
sleep_for_elapsed() {
    local elapsed=$1
    if   [ "$elapsed" -lt "$DEAD_ZONE_SEC"  ]; then echo $(( DEAD_ZONE_SEC - elapsed ))
    elif [ "$elapsed" -lt "$FAST_FAIL_SEC"  ]; then echo 30
    elif [ "$elapsed" -lt "$TEST_CEIL_SEC"  ]; then echo 60
    elif [ "$elapsed" -lt "$CEILING_SEC"    ]; then echo 90
    else echo 0  # past ceiling
    fi
}

# Return a short label for the current phase (for phase-transition logging)
phase_for_elapsed() {
    local elapsed=$1
    if   [ "$elapsed" -lt "$DEAD_ZONE_SEC" ]; then echo "dead-zone"
    elif [ "$elapsed" -lt "$FAST_FAIL_SEC" ]; then echo "fast-fail"
    elif [ "$elapsed" -lt "$TEST_CEIL_SEC" ]; then echo "test"
    elif [ "$elapsed" -lt "$CEILING_SEC"   ]; then echo "e2e"
    else echo "ceiling"
    fi
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

# On failure, check whether fast-gate specifically failed (→ downstream jobs won't run).
# Prints a diagnostic line and returns 0 if fast-gate failed, 1 otherwise.
check_fast_gate_failed() {
    local run_id="$1"
    local fg_conclusion
    fg_conclusion=$(gh run view "$run_id" --json jobs \
        --jq '.jobs[] | select(.name == "Fast Gate") | .conclusion' 2>/dev/null || echo "")
    if [ "$fg_conclusion" = "failure" ]; then
        echo "  fast-gate failed — downstream jobs were cancelled"
        return 0
    fi
    return 1
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

# ---------------------------------------------------------------------------
# Wait mode: adaptive polling calibrated to the run's own startedAt timestamp
# ---------------------------------------------------------------------------
if [ $WAIT_MODE -eq 1 ]; then
    parse_phase_ceilings

    # Fetch initial status (includes startedAt for elapsed calculation)
    STATUS_JSON=$(get_status)
    STATUS=$(echo "$STATUS_JSON" | jq -r '.status')
    CONCLUSION=$(echo "$STATUS_JSON" | jq -r '.conclusion')
    NAME=$(echo "$STATUS_JSON" | jq -r '.name')
    RUN_ID=$(echo "$STATUS_JSON" | jq -r '.databaseId')

    # If already completed on the first fetch, report immediately
    if [ "$STATUS" = "completed" ]; then
        echo "CI${BRANCH_LABEL}: $CONCLUSION ($NAME) [run: $RUN_ID]"
        if [ "$CONCLUSION" = "success" ]; then
            exit 0
        else
            check_fast_gate_failed "$RUN_ID" || true
            check_regression "$CONCLUSION" || true
            exit 1
        fi
    fi

    # Determine how long this run has already been running.
    # If the timestamp is missing or unparseable, treat the run as just started
    # (conservative: may over-wait in phase 0, never false-timeout).
    STARTED_AT=$(echo "$STATUS_JSON" | jq -r '.startedAt // .createdAt')
    STARTED_EPOCH=""
    if [ -n "$STARTED_AT" ] && [ "$STARTED_AT" != "null" ]; then
        STARTED_EPOCH=$(to_epoch "$STARTED_AT")
    fi
    if [ -z "$STARTED_EPOCH" ]; then
        STARTED_EPOCH=$(date +%s)  # unparseable → treat as just started
    fi

    ELAPSED=$(( $(date +%s) - STARTED_EPOCH ))
    CURRENT_PHASE=$(phase_for_elapsed "$ELAPSED")

    echo "Waiting for CI${BRANCH_LABEL} to complete... [run: $RUN_ID, elapsed: ${ELAPSED}s, phase: $CURRENT_PHASE]"

    while true; do
        ELAPSED=$(( $(date +%s) - STARTED_EPOCH ))

        # Hard ceiling: bail if the run has exceeded the maximum possible duration
        if [ "$ELAPSED" -ge "$CEILING_SEC" ]; then
            echo "CI${BRANCH_LABEL}: TIMEOUT — run ${RUN_ID} still in_progress after ${ELAPSED}s (ceiling: ${CEILING_SEC}s)"
            exit 1
        fi

        SLEEP_SEC=$(sleep_for_elapsed "$ELAPSED")
        NEW_PHASE=$(phase_for_elapsed "$ELAPSED")

        # Log only on phase transitions to suppress noise
        if [ "$NEW_PHASE" != "$CURRENT_PHASE" ]; then
            echo "  [$(date +%H:%M:%S)] phase: $NEW_PHASE (next poll in ${SLEEP_SEC}s)"
            CURRENT_PHASE="$NEW_PHASE"
        fi

        sleep "$SLEEP_SEC"

        STATUS_JSON=$(get_status)
        STATUS=$(echo "$STATUS_JSON" | jq -r '.status')
        CONCLUSION=$(echo "$STATUS_JSON" | jq -r '.conclusion')
        NAME=$(echo "$STATUS_JSON" | jq -r '.name')

        if [ "$STATUS" = "completed" ]; then
            ELAPSED=$(( $(date +%s) - STARTED_EPOCH ))
            echo "CI${BRANCH_LABEL}: $CONCLUSION ($NAME) [run: $RUN_ID, elapsed: ${ELAPSED}s]"
            if [ "$CONCLUSION" = "success" ]; then
                exit 0
            else
                check_fast_gate_failed "$RUN_ID" || true
                check_regression "$CONCLUSION" || true
                exit 1
            fi
        fi
    done
fi

# ---------------------------------------------------------------------------
# Default: single status check
# ---------------------------------------------------------------------------
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
