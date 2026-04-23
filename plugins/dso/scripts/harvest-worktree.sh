#!/usr/bin/env bash
# harvest-worktree.sh
# Merges a worktree branch into the current (session) branch after validating
# that the worktree's gate artifacts (test-gate-status, review-status) pass.
#
# Usage:
#   harvest-worktree.sh <worktree-branch> <worktree-artifacts-dir> [--session-artifacts <dir>] [--ticket-id <id>]
#
# Arguments:
#   worktree-branch        Git branch name to merge
#   worktree-artifacts-dir Path to the worktree's artifacts directory containing gate files
#   --session-artifacts    Optional: directory to write attested gate files for the session
#   --ticket-id            Optional: ticket ID to post a WORKTREE_TRACKING:complete comment to
#
# Exit codes:
#   0  Success (merge commit created, or branch already merged)
#   1  Conflict in non-.test-index files, or MERGE_HEAD present on entry
#   2  Gate verification failed (test-gate-status or review-status missing/failed)
#   3  Empty branch — no commits beyond expected base (agent commit was blocked)

set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────

WORKTREE_BRANCH=""
WORKTREE_ARTIFACTS_DIR=""
SESSION_ARTIFACTS_DIR=""
TICKET_ID=""
EXPECTED_BASE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-artifacts)
            SESSION_ARTIFACTS_DIR="$2"
            shift 2
            ;;
        --ticket-id)
            TICKET_ID="$2"
            shift 2
            ;;
        --expected-base)
            EXPECTED_BASE="$2"
            shift 2
            ;;
        *)
            if [[ -z "$WORKTREE_BRANCH" ]]; then
                WORKTREE_BRANCH="$1"
            elif [[ -z "$WORKTREE_ARTIFACTS_DIR" ]]; then
                WORKTREE_ARTIFACTS_DIR="$1"
            else
                echo "ERROR: unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$WORKTREE_BRANCH" || -z "$WORKTREE_ARTIFACTS_DIR" ]]; then
    echo "Usage: harvest-worktree.sh <worktree-branch> <worktree-artifacts-dir> [--session-artifacts <dir>]" >&2
    exit 1
fi

# ── Verify no MERGE_HEAD on entry ────────────────────────────────────────────

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo ".git")
_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
# Prefer the absolute shim path so `dso` works without it being on PATH.
# Fall back to bare `dso` (PATH lookup) when the shim is absent — this keeps
# the test harness working when tests inject a stub via PATH="$STUB_BIN_DIR:$PATH"
# without creating a full .claude/scripts/dso file in the temp repo.
_DSO_SHIM_PATH="${PROJECT_ROOT:-${_REPO_ROOT}}/.claude/scripts/dso"
if [[ -x "$_DSO_SHIM_PATH" ]]; then
    _DSO_SHIM="$_DSO_SHIM_PATH"
else
    _DSO_SHIM="dso"
fi

if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
    echo "ERROR: MERGE_HEAD already exists — a merge is in progress. Abort or complete it first." >&2
    exit 1
fi

# Guard against being called from inside the target worktree (d888-632b).
# When CWD is the agent worktree, HEAD resolves to WORKTREE_BRANCH itself and
# the --is-ancestor check below trivially returns true ("already merged") even
# when the branch has commits not yet in the session branch.
_current_ref=$(git symbolic-ref HEAD 2>/dev/null || echo "")
if [[ "$_current_ref" == "refs/heads/$WORKTREE_BRANCH" ]]; then
    echo "ERROR: harvest-worktree.sh must be called from the session root, not from inside the worktree being harvested. CWD is on branch '$WORKTREE_BRANCH'; cd to the session root first." >&2
    exit 1
fi

# ── Trap: clean up MERGE_HEAD on any failure ─────────────────────────────────

_harvest_exit_code=0
# shellcheck disable=SC2329  # invoked indirectly via trap
_harvest_cleanup() {
    local ec=${_harvest_exit_code:-$?}
    if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
        git merge --abort 2>/dev/null || true
    fi
    if [[ -n "${TICKET_ID:-}" ]]; then
        local outcome
        if [[ "$ec" -eq 0 ]]; then
            outcome="merged"
        else
            outcome="discarded"
        fi
        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
        "$_DSO_SHIM" ticket comment "$TICKET_ID" "WORKTREE_TRACKING:complete branch=${WORKTREE_BRANCH:-unknown} outcome=$outcome timestamp=$ts" 2>/dev/null || true
        # Clear TICKET_ID so the EXIT trap does not post a duplicate comment
        # when the ERR trap also fires and calls exit (which re-triggers EXIT).
        TICKET_ID=""
    fi
    exit "$ec"
}
trap '_harvest_exit_code=$?; _harvest_cleanup' ERR EXIT
trap '_harvest_exit_code=1; _harvest_cleanup' TERM INT HUP

# ── Detect empty branch (agent commit blocked by pre-commit gate) ─────────────
# If a base commit is known (via --expected-base or artifacts/base-commit), check
# whether the branch tip advanced past that base. If not, the agent's commit was
# blocked and no work was integrated — emit EMPTY_BRANCH (exit 3) rather than
# silently treating the empty branch as "already merged" (1eda-6a0c).

if [[ -z "$EXPECTED_BASE" && -f "$WORKTREE_ARTIFACTS_DIR/base-commit" ]]; then
    EXPECTED_BASE=$(head -1 "$WORKTREE_ARTIFACTS_DIR/base-commit" 2>/dev/null | tr -d '[:space:]')
fi

if [[ -n "$EXPECTED_BASE" ]]; then
    _branch_tip=$(git rev-parse "$WORKTREE_BRANCH" 2>/dev/null || echo "")
    if [[ "$_branch_tip" == "$EXPECTED_BASE" ]]; then
        echo "EMPTY_BRANCH: $WORKTREE_BRANCH tip ($EXPECTED_BASE) == expected base — agent commit was likely blocked by a pre-commit gate. No work to harvest." >&2
        echo "  To recover: re-enter the worktree, fix the gate failure, commit, and re-run harvest." >&2
        _harvest_exit_code=3
        exit 3
    fi
fi

# ── Check if branch is already merged ────────────────────────────────────────

if git merge-base --is-ancestor "$WORKTREE_BRANCH" HEAD 2>/dev/null; then
    echo "Branch $WORKTREE_BRANCH is already merged — nothing to do." >&2
    _harvest_exit_code=0
    exit 0
fi

# ── Verify gate artifacts ────────────────────────────────────────────────────

# Check test-gate-status
if [[ ! -f "$WORKTREE_ARTIFACTS_DIR/test-gate-status" ]]; then
    echo "ERROR: test-gate-status not found in $WORKTREE_ARTIFACTS_DIR" >&2
    _harvest_exit_code=2
    exit 2
fi

TEST_GATE_STATUS=$(head -1 "$WORKTREE_ARTIFACTS_DIR/test-gate-status")
if [[ "$TEST_GATE_STATUS" != "passed" ]]; then
    # Check if all failed tests are covered by RED markers in the worktree's
    # .test-index. When a worktree contains only RED test files, record-test-status.sh
    # may write failed (all failures in RED zone that weren't fully tolerated). If
    # every test in failed_tests has a RED marker entry, the harvest is exempt (6810-8607).
    _failed_tests=$(grep '^failed_tests=' "$WORKTREE_ARTIFACTS_DIR/test-gate-status" 2>/dev/null | head -1 | cut -d= -f2-) || true
    _worktree_testindex=$(git show "$WORKTREE_BRANCH:.test-index" 2>/dev/null || echo "")
    _all_red_exempt=false
    if [[ -n "$_failed_tests" ]] && [[ -n "$_worktree_testindex" ]]; then
        _all_red_exempt=true
        while IFS= read -r _ft; do
            [[ -z "$_ft" ]] && continue
            if ! echo "$_worktree_testindex" | grep -qF "$_ft ["; then
                _all_red_exempt=false
                break
            fi
        done < <(echo "$_failed_tests" | tr ',' '\n')
    fi
    if [[ "$_all_red_exempt" != "true" ]]; then
        echo "ERROR: test-gate-status is '$TEST_GATE_STATUS' (expected 'passed')" >&2
        _harvest_exit_code=2
        exit 2
    fi
    # All failed tests are RED-marker-covered — rewrite status to "passed" so
    # the --attest call below can proceed (attestation reads line 1 for status).
    echo "INFO: test-gate-status '$TEST_GATE_STATUS' — all failed tests have RED markers, rewriting as red-marker-exempt passed" >&2
    _tgs_rest=$(tail -n +2 "$WORKTREE_ARTIFACTS_DIR/test-gate-status" 2>/dev/null || echo "")
    printf 'passed\n%s\nred_marker_exempt=true\n' "$_tgs_rest" > "$WORKTREE_ARTIFACTS_DIR/test-gate-status"
fi

# Check review-status
if [[ ! -f "$WORKTREE_ARTIFACTS_DIR/review-status" ]]; then
    echo "ERROR: review-status not found in $WORKTREE_ARTIFACTS_DIR" >&2
    _harvest_exit_code=2
    exit 2
fi

REVIEW_STATUS=$(head -1 "$WORKTREE_ARTIFACTS_DIR/review-status")
if [[ "$REVIEW_STATUS" != "passed" ]]; then
    echo "ERROR: review-status is '$REVIEW_STATUS' (expected 'passed')" >&2
    _harvest_exit_code=2
    exit 2
fi

# ── Merge ────────────────────────────────────────────────────────────────────

# Use `|| merge_exit=$?` so the ERR trap cannot fire if git exits non-zero on
# conflict. set +e is insufficient: bash fires the ERR trap on non-zero exit
# even when errexit is disabled (bug 0fc6-c970). Commands on the left side of
# `||` are exempt from the ERR trap, keeping the script alive so we can read
# CONFLICTED_FILES and distinguish conflicts from other git errors.
merge_exit=0
git merge --no-commit "$WORKTREE_BRANCH" >/dev/null 2>&1 || merge_exit=$?

CONFLICTED_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

# If the merge failed for a non-conflict reason (e.g., branch not found,
# read-only filesystem) CONFLICTED_FILES will be empty and MERGE_HEAD absent.
# Surface the error explicitly so the operator sees an actionable message.
if [[ "$merge_exit" -ne 0 ]] && [[ -z "$CONFLICTED_FILES" ]]; then
    echo "ERROR: git merge failed (exit $merge_exit) — check: branch exists, filesystem writable, objects not corrupted" >&2
    _harvest_exit_code=1
    exit 1
fi

if [[ -n "$CONFLICTED_FILES" ]]; then
    # Check if ALL conflicts are in .test-index (union driver handles those)
    NON_TEST_INDEX_CONFLICTS=""
    while IFS= read -r cfile; do
        [[ -z "$cfile" ]] && continue
        if [[ "$cfile" != ".test-index" ]]; then
            NON_TEST_INDEX_CONFLICTS+="$cfile"$'\n'
        fi
    done <<< "$CONFLICTED_FILES"

    if [[ -n "$NON_TEST_INDEX_CONFLICTS" ]]; then
        echo "ERROR: merge conflicts in non-.test-index files:" >&2
        echo "$NON_TEST_INDEX_CONFLICTS" >&2
        git merge --abort 2>/dev/null || true
        _harvest_exit_code=1
        exit 1
    fi
    # Only .test-index conflicts — union driver should have resolved them.
    # Mark as resolved explicitly in case the union driver is misconfigured.
    git add .test-index 2>/dev/null || true
fi

# ── Attest gate status to session artifacts ──────────────────────────────────

# Determine session artifacts directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT_HW="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -z "$SESSION_ARTIFACTS_DIR" ]]; then
    # Use the current repo's artifacts dir
    if [[ -f "$_PLUGIN_ROOT_HW/hooks/lib/deps.sh" ]]; then
        source "$_PLUGIN_ROOT_HW/hooks/lib/deps.sh"
        SESSION_ARTIFACTS_DIR=$(get_artifacts_dir 2>/dev/null || echo "")
    fi
fi

if [[ -n "$SESSION_ARTIFACTS_DIR" ]]; then
    mkdir -p "$SESSION_ARTIFACTS_DIR"

    HOOK_DIR="$_PLUGIN_ROOT_HW/hooks"

    # Attest test gate status with post-merge diff hash (f518-bba6).
    # --attest validates the worktree's status is "passed", then writes a new
    # test-gate-status with the session's current diff_hash so pre-commit gates match.
    # Export WORKFLOW_PLUGIN_ARTIFACTS_DIR so get_artifacts_dir() in the attest
    # scripts writes to the session artifacts dir (not the default hash-based path).
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_DIR" \
        bash "$HOOK_DIR/record-test-status.sh" --attest "$WORKTREE_ARTIFACTS_DIR"

    # Attest review status with post-merge diff hash.
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_DIR" \
        bash "$HOOK_DIR/record-review.sh" --attest "$WORKTREE_ARTIFACTS_DIR"
fi

# ── Commit ───────────────────────────────────────────────────────────────────

# If merge was a fast-forward (no MERGE_HEAD), git already committed
if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
    git commit --no-edit >/dev/null 2>&1
fi

# ── Post-merge cleanup ───────────────────────────────────────────────────────
# Fixes bug afdb-8418: before this block, harvest-worktree.sh left both the
# agent worktree and its backing branch in place, requiring cleanup via a
# separate orchestrator step (per-worktree-review-commit.md Step 7) that fails
# to run when auto-compact drops the orchestrator's state between harvest and
# cleanup, or when the dispatching skill (fix-bug, debug-everything) does not
# invoke that step at all. Making cleanup the harvest script's own responsibility
# removes the LLM-in-loop dependency: cleanup runs deterministically whenever
# the merge succeeds, regardless of which orchestrator dispatched the agent.
#
# All cleanup operations are best-effort (|| true): failure here must not
# corrupt exit status — the merge already succeeded.
_harvest_worktree_path=$(git worktree list --porcelain 2>/dev/null | awk -v b="$WORKTREE_BRANCH" '
    /^worktree / { p = substr($0, 10) }
    $0 == "branch refs/heads/" b { print p; exit }
')
if [[ -n "$_harvest_worktree_path" ]]; then
    _harvest_session_root=$(git rev-parse --show-toplevel 2>/dev/null)
    # Never remove the caller's own working tree (would orphan the shell).
    # Also skip branch deletion when the guard fires: git rejects deleting the
    # currently-checked-out branch anyway, and attempting it is misleading (a44a-0f63).
    if [[ "$_harvest_worktree_path" != "$_harvest_session_root" ]]; then
        git worktree unlock "$_harvest_worktree_path" 2>/dev/null || true
        git worktree remove "$_harvest_worktree_path" --force 2>/dev/null || true
        git worktree prune 2>/dev/null || true
        git branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
    fi
else
    # No backing worktree — delete the branch directly.
    git branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
fi

_harvest_exit_code=0

# ── Read PRECONDITIONS context (informational, fail-open) ────────────────────
# Source ticket-lib.sh to get _read_latest_preconditions; read the preconditions
# summary for the ticket being harvested and log it. Fails gracefully for legacy
# tickets with zero PRECONDITIONS events (pre-manifest state).
if [[ -f "$SCRIPT_DIR/ticket-lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/ticket-lib.sh" 2>/dev/null || true
    if [[ -n "${TICKET_ID:-}" ]] && declare -f _read_latest_preconditions >/dev/null 2>&1; then
        _ticket_dir="${_REPO_ROOT}/.tickets-tracker/${TICKET_ID}"
        _preconditions_json=""
        _preconditions_json=$(_read_latest_preconditions "$_ticket_dir" 2>/dev/null) || true
        if [[ -n "$_preconditions_json" ]]; then
            echo "[harvest] preconditions: $_preconditions_json" >&2
        else
            echo "[harvest] preconditions: pre-manifest (no PRECONDITIONS events for $TICKET_ID)" >&2
        fi
    fi
fi

echo "Worktree $WORKTREE_BRANCH merged successfully" >&2
exit 0
