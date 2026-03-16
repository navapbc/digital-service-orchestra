#!/bin/bash
set -uo pipefail
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
# --wait uses SHA-anchored polling at a flat 30s interval:
#   - Resolves the HEAD SHA of the tracked branch to find the exact CI run
#   - Waits up to 90s for the run to appear (runner startup delay)
#   - Skips polling during the 45s dead zone (no CI signal possible yet)
#   - Polls via `gh run view <id>` — tracks the specific run, not latest-by-branch
#   - Hard ceiling derived from ci.yml timeout-minutes; exits 1 on timeout
#
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

# ---------------------------------------------------------------------------
# Auth pre-flight check: verify gh is authenticated before making any API calls.
# An unauthenticated gh silently fails on every API call, causing --wait mode
# to enter an infinite polling loop. Fail fast with a clear message instead.
# ---------------------------------------------------------------------------
if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh is not authenticated. Run 'gh auth login' to authenticate before using ci-status.sh." >&2
    exit 1
fi

# --check-jobs: print one line per job for a given run ID
if [ -n "$CHECK_JOBS_RUN_ID" ]; then
    run_json=$(gh run view "$CHECK_JOBS_RUN_ID" --json jobs,conclusion 2>/dev/null)
    run_conclusion=$(echo "$run_json" | jq -r '.conclusion // ""')
    if [ "$run_conclusion" = "cancelled" ]; then
        echo "# WARNING: run $CHECK_JOBS_RUN_ID was CANCELLED — 'failure' conclusions below may be spurious (cancellation-induced via exit 1 trap)"
    fi
    echo "$run_json" | jq -r '.jobs[] | "\(.conclusion) \(.name)"'
    exit 0
fi

# Auto-detect: in a worktree, default to main branch
# (SCRIPT_DIR is set unconditionally below; define REPO_ROOT here for .git check)
if [ -z "$BRANCH" ]; then
    _autodetect_script_dir="$(cd "$(dirname "$0")" && pwd)"
    REPO_ROOT="$(cd "$_autodetect_script_dir/.." && git rev-parse --show-toplevel 2>/dev/null || echo "$_autodetect_script_dir/..")"
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

# SCRIPT_DIR is used both for worktree detection above and for config reading below.
# Set it unconditionally here so it is always available regardless of BRANCH state.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read CI job names from workflow-config.conf (via read-config.sh).
# Falls back to sensible defaults so the script works without a config file.
_cfg() { "$SCRIPT_DIR/read-config.sh" "$1" 2>/dev/null; }
_val=$(_cfg ci.fast_gate_job); FAST_GATE_JOB="${_val:-Fast Gate}"
_val=$(_cfg ci.fast_fail_job); FAST_FAIL_JOB="${_val:-$FAST_GATE_JOB}"
_val=$(_cfg ci.test_ceil_job); TEST_CEIL_JOB="${_val:-Unit Tests}"
unset -f _cfg; unset _val

# Get latest CI workflow run — includes startedAt/createdAt for elapsed calculation
get_status() {
    gh run list --workflow=CI $GH_BRANCH_FLAG --limit 1 \
        --json databaseId,status,conclusion,name,startedAt,createdAt \
        | jq '.[0]'
}

# Find CI run for a specific HEAD commit SHA.
# Fetches the last 5 runs and returns the first one whose headSha matches.
# Retries for up to 90s to allow for runner startup delay after a push.
# Prints JSON on success; returns 1 if not found after timeout.
find_run_for_sha() {
    local target_sha="$1"
    local deadline=$(( $(date +%s) + 90 ))
    while true; do
        local run_json
        run_json=$(gh run list --workflow=CI $GH_BRANCH_FLAG --limit 5 \
            --json databaseId,status,conclusion,name,startedAt,createdAt,headSha \
            2>/dev/null | jq --arg sha "$target_sha" \
            'map(select(.headSha == $sha)) | .[0] // empty' || echo "")
        if [ -n "$run_json" ]; then
            echo "$run_json"
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            return 1
        fi
        sleep 10
    done
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
        # macOS — use -u to interpret input as UTC (GitHub API returns UTC timestamps)
        result=$(date -u -jf "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null || true)
    fi
    echo "$result"
}

# Source deps.sh for parse_json_field (jq fallback) and other utilities.
_ci_deps_sh="${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
[[ -f "$_ci_deps_sh" ]] && source "$_ci_deps_sh"

# ci_parse_json <json> <field_expr>
# Extract a simple JSON field. Tries jq first; falls back to parse_json_field
# from deps.sh when jq is not installed or fails.
# Emits a one-time warning to stderr on fallback.
# NOTE: Only handles simple top-level field expressions (e.g. '.status', '.name').
# Complex jq expressions (arrays, filters, argument passing) still require jq.
_CI_JQ_WARNED=0
ci_parse_json() {
    local json="$1"
    local expr="$2"
    local result
    result=$(echo "$json" | jq -r "$expr" 2>/dev/null)
    if [ $? -ne 0 ]; then
        if [ "$_CI_JQ_WARNED" -eq 0 ]; then
            echo "ci-status: jq not found, using parse_json_field fallback" >&2
            _CI_JQ_WARNED=1
        fi
        result=$(parse_json_field "$json" "$expr")
    fi
    echo "$result"
}

# Source config-paths.sh for CFG_PYTHON_VENV
_ci_config_paths="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"
[[ -f "$_ci_config_paths" ]] && source "$_ci_config_paths"

# Resolve a python3 interpreter that has PyYAML installed.
# Uses the same probe order as read-config.sh: CLAUDE_PLUGIN_PYTHON env var,
# config-driven venv (CFG_PYTHON_VENV), .venv, then system python3.
# Prints the path on success; empty string if none found.
_find_python_with_yaml() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    local candidate
    for candidate in \
        "${CLAUDE_PLUGIN_PYTHON:-}" \
        "${repo_root:+$repo_root/$CFG_PYTHON_VENV}" \
        "${repo_root:+$repo_root/.venv/bin/python3}" \
        "python3"; do
        [[ -z "$candidate" ]] && continue
        [[ "$candidate" != "python3" ]] && [[ ! -f "$candidate" ]] && continue
        if "$candidate" -c "import yaml" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
}

# Extract timeout-minutes for a named job from ci.yml.
# Matches by the job's `name:` display value (not the YAML key).
# Returns empty string if the job is not found or PyYAML is unavailable.
# Emits a warning to stderr if the named job is not found in the YAML.
get_job_timeout_min() {
    local yaml="$1"
    local job_name="$2"
    local python
    python=$(_find_python_with_yaml)
    if [[ -z "$python" ]]; then
        echo "Warning: no python3 with PyYAML found; cannot read CI job timeouts from $yaml" >&2
        return 0
    fi
    "$python" - "$yaml" "$job_name" <<'PYEOF'
import sys
try:
    import yaml as _yaml
    with open(sys.argv[1]) as f:
        data = _yaml.safe_load(f)
    for job in (data or {}).get("jobs", {}).values():
        if job.get("name") == sys.argv[2]:
            t = job.get("timeout-minutes")
            if t is not None:
                print(t)
            sys.exit(0)
    print(f"Warning: CI job '{sys.argv[2]}' not found in {sys.argv[1]}", file=sys.stderr)
except FileNotFoundError:
    pass  # ci.yml absent — parse_phase_ceilings uses hardcoded fallback
except Exception as e:
    print(f"Warning: error parsing {sys.argv[1]}: {e}", file=sys.stderr)
PYEOF
}

# Parse phase ceilings from ci.yml timeout-minutes values.
# FAST_FAIL_SEC and TEST_CEIL_SEC are derived from the job names configured
# in workflow-config.conf (ci.fast_fail_job and ci.test_ceil_job).
# Sets globals: DEAD_ZONE_SEC, FAST_FAIL_SEC, TEST_CEIL_SEC, CEILING_SEC
parse_phase_ceilings() {
    local yaml=""
    # Locate ci.yml relative to this script (works from worktree or main repo)
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    local _ci_repo_root
    _ci_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    local candidate="${_ci_repo_root:+$_ci_repo_root/.github/workflows/ci.yml}"
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        yaml="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
    fi

    DEAD_ZONE_SEC=45

    if [ -z "$yaml" ]; then
        # Fallback: hardcoded values matching current ci.yml
        FAST_FAIL_SEC=180    # 3 min
        TEST_CEIL_SEC=900    # 15 min
        CEILING_SEC=1320     # 22 min (E2E 20min + 2min buffer)
        return
    fi

    # Absolute ceiling: max timeout-minutes across all jobs + 2min buffer
    local all_timeouts max_timeout
    all_timeouts=$(grep 'timeout-minutes:' "$yaml" | awk '{print $2}' | grep -E '^[0-9]+$' || true)
    max_timeout=$(echo "$all_timeouts" | sort -rn | head -1)
    CEILING_SEC=$(( max_timeout * 60 + 120 ))

    # Fast-fail phase end: timeout of the configured fast_fail_job
    local ff_min
    ff_min=$(get_job_timeout_min "$yaml" "$FAST_FAIL_JOB")
    FAST_FAIL_SEC=$(( ${ff_min:-3} * 60 ))   # fallback 3 min if job not found

    # Test phase end: timeout of the configured test_ceil_job
    local tc_min
    tc_min=$(get_job_timeout_min "$yaml" "$TEST_CEIL_JOB")
    TEST_CEIL_SEC=$(( ${tc_min:-15} * 60 ))  # fallback 15 min if job not found
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

    # A cancelled run is not a test failure — skip regression analysis for it
    if [ "$current_conclusion" = "cancelled" ]; then
        return 0
    fi

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

# On failure, check whether the fast-gate job specifically failed (→ downstream jobs
# won't run). Uses the job name from workflow-config.conf (ci.fast_gate_job).
# Prints a diagnostic line and returns 0 if fast-gate failed, 1 otherwise.
check_fast_gate_failed() {
    local run_id="$1"
    local fg_conclusion
    fg_conclusion=$(gh run view "$run_id" --json jobs \
        2>/dev/null | jq -r --arg name "$FAST_GATE_JOB" \
        '.jobs[] | select(.name == $name) | .conclusion' || echo "")
    if [ "$fg_conclusion" = "failure" ]; then
        echo "  $FAST_GATE_JOB failed — downstream jobs were cancelled"
        return 0
    fi
    return 1
}

# Get run ID only
if [ $ID_ONLY -eq 1 ]; then
    gh run list --workflow=CI $GH_BRANCH_FLAG --limit 1 --json databaseId | jq -r '.[0].databaseId'
    exit 0
fi

BRANCH_LABEL=""
if [ -n "$BRANCH" ]; then
    BRANCH_LABEL=" ($BRANCH)"
fi

# ---------------------------------------------------------------------------
# Wait mode: SHA-anchored polling at flat 30s intervals
# ---------------------------------------------------------------------------
if [ $WAIT_MODE -eq 1 ]; then
    parse_phase_ceilings

    # Resolve the HEAD SHA of the tracked branch for deterministic run discovery.
    # Prefer the remote branch SHA so we track the exact pushed commit.
    TARGET_SHA=""
    if [ -n "$BRANCH" ]; then
        TARGET_SHA=$(git ls-remote origin "$BRANCH" 2>/dev/null | awk '{print $1}' | head -1 || echo "")
    fi
    if [ -z "$TARGET_SHA" ]; then
        TARGET_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
    fi

    # Find the CI run for this SHA, waiting up to 90s for it to appear.
    STATUS_JSON=""
    if [ -n "$TARGET_SHA" ]; then
        echo "Looking for CI run for commit ${TARGET_SHA:0:8}..."
        STATUS_JSON=$(find_run_for_sha "$TARGET_SHA" || echo "")
        if [ -z "$STATUS_JSON" ]; then
            echo "Warning: no run found for SHA ${TARGET_SHA:0:8} after 90s — falling back to latest run"
        fi
    fi
    if [ -z "$STATUS_JSON" ]; then
        STATUS_JSON=$(get_status)
    fi

    STATUS=$(ci_parse_json "$STATUS_JSON" '.status')
    CONCLUSION=$(ci_parse_json "$STATUS_JSON" '.conclusion')
    NAME=$(ci_parse_json "$STATUS_JSON" '.name')
    RUN_ID=$(ci_parse_json "$STATUS_JSON" '.databaseId')

    # If already completed on the first fetch, report immediately
    if [ "$STATUS" = "completed" ]; then
        echo "CI${BRANCH_LABEL}: $CONCLUSION ($NAME) [run: $RUN_ID]"
        if [ "$CONCLUSION" = "success" ]; then
            exit 0
        elif [ "$CONCLUSION" = "cancelled" ]; then
            echo "  (run $RUN_ID was cancelled — not a test failure)"
            exit 0
        else
            check_fast_gate_failed "$RUN_ID" || true
            check_regression "$CONCLUSION" || true
            exit 1
        fi
    fi

    # Determine how long this run has already been running.
    # If the timestamp is missing or unparseable, treat the run as just started
    # (conservative: may over-wait in dead zone, never false-timeout).
    # Extract startedAt, falling back to createdAt if absent/null
    STARTED_AT=$(ci_parse_json "$STATUS_JSON" '.startedAt')
    if [ -z "$STARTED_AT" ] || [ "$STARTED_AT" = "null" ]; then
        STARTED_AT=$(ci_parse_json "$STATUS_JSON" '.createdAt')
    fi
    STARTED_EPOCH=""
    if [ -n "$STARTED_AT" ] && [ "$STARTED_AT" != "null" ]; then
        STARTED_EPOCH=$(to_epoch "$STARTED_AT")
    fi
    if [ -z "$STARTED_EPOCH" ]; then
        STARTED_EPOCH=$(date +%s)  # unparseable → treat as just started
    fi

    ELAPSED=$(( $(date +%s) - STARTED_EPOCH ))
    # Clamp to 0 if negative (timestamp parsing edge cases, e.g. TZ skew)
    if [ "$ELAPSED" -lt 0 ]; then
        ELAPSED=0
    fi

    # Wait out the dead zone before first poll (no CI signal possible during runner startup)
    if [ "$ELAPSED" -lt "$DEAD_ZONE_SEC" ]; then
        WAIT_SECS=$(( DEAD_ZONE_SEC - ELAPSED ))
        echo "Waiting for CI${BRANCH_LABEL}... [run: $RUN_ID, dead zone — first poll in ${WAIT_SECS}s]"
        sleep "$WAIT_SECS"
    else
        echo "Waiting for CI${BRANCH_LABEL}... [run: $RUN_ID, elapsed: ${ELAPSED}s]"
    fi

    # Max-iteration ceiling: 60 iterations × 30s = 30 minutes maximum.
    # Prevents infinite polling loops when CI status is stuck or never transitions.
    MAX_POLL_ITERATIONS=60
    _poll_iteration=0

    while true; do
        ELAPSED=$(( $(date +%s) - STARTED_EPOCH ))

        # Max-iteration ceiling check (complements the time-based CEILING_SEC check)
        _poll_iteration=$(( _poll_iteration + 1 ))
        if [ "$_poll_iteration" -gt "$MAX_POLL_ITERATIONS" ]; then
            echo "CI${BRANCH_LABEL}: TIMEOUT — run ${RUN_ID} still in_progress after ${_poll_iteration} poll iterations (max: ${MAX_POLL_ITERATIONS})"
            exit 1
        fi

        # Hard ceiling: bail if the run has exceeded the maximum possible duration
        if [ "$ELAPSED" -ge "$CEILING_SEC" ]; then
            echo "CI${BRANCH_LABEL}: TIMEOUT — run ${RUN_ID} still in_progress after ${ELAPSED}s (ceiling: ${CEILING_SEC}s)"
            exit 1
        fi

        # Poll the specific run by ID — avoids returning a different run from the branch.
        # Capture stderr to detect rate-limit responses (HTTP 429/403).
        _gh_stderr_file=$(mktemp)
        RUN_JSON=$(gh run view "$RUN_ID" \
            --json status,conclusion,name \
            2>"$_gh_stderr_file" || echo "")
        _gh_stderr=$(cat "$_gh_stderr_file" 2>/dev/null || echo "")
        rm -f "$_gh_stderr_file"

        # Rate-limit detection: if GitHub returns a 429 or rate limit error, back off
        # and retry rather than treating it as an empty/failed response.
        # backoff delays: 30s, 60s, 120s (max 3 retries before continuing normal polling)
        if echo "$_gh_stderr $RUN_JSON" | grep -qiE "rate.limit|429|API rate"; then
            echo "ci-status: GitHub API rate limit detected — backing off before next poll" >&2
            _backoff_delay=30
            _backoff_retries=0
            while [ "$_backoff_retries" -lt 3 ]; do
                # Check elapsed time before sleeping — rate-limit backoff must not
                # bypass the overall CEILING_SEC timeout
                ELAPSED=$(( $(date +%s) - START ))
                if [ "$ELAPSED" -ge "$CEILING_SEC" ]; then
                    echo "CI${BRANCH_LABEL}: TIMEOUT — ceiling ${CEILING_SEC}s reached during rate-limit backoff" >&2
                    exit 1
                fi
                echo "ci-status: rate-limit backoff: sleeping ${_backoff_delay}s (retry $((_backoff_retries + 1))/3)" >&2
                sleep "$_backoff_delay"
                _backoff_delay=$(( _backoff_delay * 2 ))
                _backoff_retries=$(( _backoff_retries + 1 ))
                _gh_stderr_retry=$(mktemp)
                RUN_JSON=$(gh run view "$RUN_ID" \
                    --json status,conclusion,name \
                    2>"$_gh_stderr_retry" || echo "")
                _gh_stderr_retry_content=$(cat "$_gh_stderr_retry" 2>/dev/null || echo "")
                rm -f "$_gh_stderr_retry"
                # If no longer rate-limited, break out of backoff loop
                if ! echo "$_gh_stderr_retry_content $RUN_JSON" | grep -qiE "rate.limit|429|API rate"; then
                    break
                fi
            done
            if [ "$_backoff_retries" -ge 3 ]; then
                echo "ci-status: rate-limit backoff exhausted after 3 retries — exiting" >&2
                exit 1
            fi
        fi

        STATUS=$(ci_parse_json "$RUN_JSON" '.status')
        CONCLUSION=$(ci_parse_json "$RUN_JSON" '.conclusion')
        NAME=$(ci_parse_json "$RUN_JSON" '.name')

        if [ "$STATUS" = "completed" ]; then
            ELAPSED=$(( $(date +%s) - STARTED_EPOCH ))
            echo "CI${BRANCH_LABEL}: $CONCLUSION ($NAME) [run: $RUN_ID, elapsed: ${ELAPSED}s]"
            if [ "$CONCLUSION" = "success" ]; then
                exit 0
            elif [ "$CONCLUSION" = "cancelled" ]; then
                echo "  (run $RUN_ID was cancelled — not a test failure)"
                exit 0
            else
                check_fast_gate_failed "$RUN_ID" || true
                check_regression "$CONCLUSION" || true
                exit 1
            fi
        fi

        sleep 30
    done
fi

# ---------------------------------------------------------------------------
# Default: single status check
# ---------------------------------------------------------------------------
STATUS_JSON=$(get_status)
STATUS=$(ci_parse_json "$STATUS_JSON" '.status')
CONCLUSION=$(ci_parse_json "$STATUS_JSON" '.conclusion')
NAME=$(ci_parse_json "$STATUS_JSON" '.name')
RUN_ID=$(ci_parse_json "$STATUS_JSON" '.databaseId')

if [ "$STATUS" = "completed" ]; then
    echo "CI${BRANCH_LABEL}: $CONCLUSION ($NAME) [run: $RUN_ID]"
    if [ "$CONCLUSION" = "success" ]; then
        exit 0
    elif [ "$CONCLUSION" = "cancelled" ]; then
        echo "  (run $RUN_ID was cancelled — not a test failure)"
        exit 0
    else
        check_regression "$CONCLUSION" || true
        exit 1
    fi
else
    echo "CI${BRANCH_LABEL}: $STATUS ($NAME) [run: $RUN_ID]"
    exit 2  # Exit code 2 = still running
fi
