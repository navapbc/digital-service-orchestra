#!/usr/bin/env bash
# wait-for-pr.sh — poll a PR for terminal state with proper failure detection.
#
# Closes 83db-5923: until-loops that only watch for `state == MERGED` keep
# polling indefinitely when CI fails or the PR is closed without merging.
# This wrapper exits as soon as any terminal state is reached.
#
# Exit codes:
#   0  — PR merged successfully (or already merged at first poll)
#   1  — PR closed without merging, or required checks failed, or auto-merge
#         was queued and then disabled, or timeout reached
#   2  — usage error
#
# Usage:
#   wait-for-pr.sh <pr_number> [--interval=SECONDS] [--timeout=SECONDS] [--repo=OWNER/REPO]
#
# Defaults: interval=60, timeout=3600.

set -uo pipefail

PR=""
INTERVAL=60
TIMEOUT=3600
REPO_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval=*) INTERVAL="${1#--interval=}" ;;
        --timeout=*)  TIMEOUT="${1#--timeout=}" ;;
        --repo=*)     REPO_ARGS+=(--repo "${1#--repo=}") ;;
        -h|--help)
            grep -E '^# ' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        --*) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
        *)
            if [[ -z "$PR" ]]; then PR="$1"
            else echo "ERROR: extra positional arg: $1" >&2; exit 2
            fi
            ;;
    esac
    shift
done

if [[ -z "$PR" ]]; then
    echo "ERROR: pr_number is required. Usage: wait-for-pr.sh <pr_number> [--interval=N] [--timeout=N]" >&2
    exit 2
fi

# Numeric guards
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || ! [[ "$PR" =~ ^[0-9]+$ ]]; then
    echo "ERROR: pr_number, --interval, and --timeout must all be positive integers" >&2
    exit 2
fi

# Allow tests to inject a stub gh command via GH_CMD.
GH_CMD="${GH_CMD:-gh}"

# _view sets _VIEW_OUT and _VIEW_RC. Stderr is captured separately into
# _VIEW_ERR so the caller can distinguish auth/permission failures (where gh
# returns a clear error message and a non-zero exit) from transient empty
# output (network blip, rate limit retry-able).
_view() {
    local _err_file
    _err_file=$(mktemp /tmp/wait-for-pr-err.XXXXXX)
    _VIEW_RC=0
    _VIEW_OUT=$("$GH_CMD" pr view "$PR" "${REPO_ARGS[@]}" \
        --json state,mergedAt,statusCheckRollup,autoMergeRequest,mergeable 2>"$_err_file") || _VIEW_RC=$?
    _VIEW_ERR=$(cat "$_err_file" 2>/dev/null || echo "")
    rm -f "$_err_file"
}

# _is_fatal_gh_error inspects _VIEW_ERR for unrecoverable signals — auth /
# permission / not-found — and returns 0 (match) when one is found. Network
# blips and rate limits remain retryable.
_is_fatal_gh_error() {
    local err="$_VIEW_ERR"
    if [[ -z "$err" ]]; then
        return 1
    fi
    # gh prints these messages for unrecoverable conditions
    if echo "$err" | grep -qiE "could not resolve to a (pullrequest|node)|not found|authentication|HTTP 401|HTTP 403|permission denied|bad credentials"; then
        return 0
    fi
    return 1
}

_classify() {
    # Reads a JSON payload from stdin; emits one of:
    #   MERGED | CLOSED | FAILED | PENDING | UNKNOWN
    # to stdout, with the reason as an optional second token.
    # NOTE: use -c (not -) so the heredoc isn't consumed as python's stdin,
    # which would block sys.stdin from receiving the piped JSON.
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("UNKNOWN unparseable")
    sys.exit(0)
state = d.get("state") or ""
if state == "MERGED":
    print("MERGED")
    sys.exit(0)
if state == "CLOSED":
    print("CLOSED closed-without-merge")
    sys.exit(0)
checks = d.get("statusCheckRollup") or []
bad = [c for c in checks if (c.get("conclusion") or "") in ("FAILURE", "TIMED_OUT", "CANCELLED")]
if bad:
    names = ",".join(c.get("name", "?") for c in bad[:5])
    print("FAILED checks=" + names)
    sys.exit(0)
print("PENDING")
'
}

deadline=$(( $(date +%s) + TIMEOUT ))

# Track auto-merge across polls so we can detect a non-null -> null transition
# (auto-merge queued and then disabled by a reviewer). _ever_had_auto=1 means
# at least one prior poll saw autoMergeRequest != null.
_ever_had_auto=0

while true; do
    _view
    out="$_VIEW_OUT"
    # Distinguish unrecoverable gh errors (auth/permission/not-found) from
    # transient ones. Fatal errors fail fast so the operator gets an actionable
    # message instead of waiting out the full timeout.
    if [[ "$_VIEW_RC" -ne 0 ]] && _is_fatal_gh_error; then
        echo "ERROR: gh pr view failed unrecoverably for PR #$PR:" >&2
        echo "$_VIEW_ERR" >&2
        exit 1
    fi
    if [[ -z "$out" ]]; then
        if [[ -n "$_VIEW_ERR" ]]; then
            echo "WARNING: gh pr view rc=$_VIEW_RC stderr: $_VIEW_ERR" >&2
        else
            echo "WARNING: gh pr view returned empty output; retrying after $INTERVAL s" >&2
        fi
        if (( $(date +%s) >= deadline )); then
            echo "ERROR: timeout waiting for PR #$PR (no response from gh)" >&2
            exit 1
        fi
        sleep "$INTERVAL"
        continue
    fi

    # Fast conflict detection: a CONFLICTING (DIRTY) PR will NEVER get its
    # required checks run by GitHub — it cannot compute the merge ref, so the
    # check-based poll below would spin until --timeout (and any auto-merge
    # never fires). Detect mergeable == CONFLICTING and exit fast (exit 1) so
    # the caller/orchestrator can resolve the conflict (rebase) and retry,
    # instead of dead-waiting the full timeout. mergeable is UNKNOWN while
    # GitHub computes mergeability and MERGEABLE when clean, so CONFLICTING is
    # a definitive terminal signal — safe to act on immediately.
    _mergeable=$(printf '%s\n' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); sys.exit(0)
print(d.get("mergeable") or "?")
')
    if [[ "$_mergeable" == "CONFLICTING" ]]; then
        echo "ERROR: PR #$PR has merge conflicts (mergeable=CONFLICTING) — GitHub will not run required checks on a conflicting PR. Resolve the conflict (rebase onto the base) and retry." >&2
        exit 1
    fi

    # Auto-merge transition check (non-null -> null while OPEN) — must run
    # BEFORE _classify since _classify only knows the current poll's payload.
    _auto_present=$(printf '%s\n' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); sys.exit(0)
amr = d.get("autoMergeRequest")
state = d.get("state") or ""
print("1" if amr else ("0" if state == "OPEN" else "?"))
')
    if [[ "$_auto_present" == "1" ]]; then
        _ever_had_auto=1
    elif [[ "$_auto_present" == "0" && "$_ever_had_auto" == "1" ]]; then
        echo "ERROR: PR #$PR auto-merge was queued then disabled" >&2
        exit 1
    fi

    read -r status reason <<< "$(printf '%s\n' "$out" | _classify)"
    case "$status" in
        MERGED)
            echo "MERGED PR #$PR" >&2
            exit 0
            ;;
        CLOSED)
            echo "ERROR: PR #$PR closed without merging ($reason)" >&2
            exit 1
            ;;
        FAILED)
            echo "ERROR: PR #$PR has failed required check(s): $reason" >&2
            exit 1
            ;;
        PENDING|UNKNOWN)
            : # keep polling
            ;;
    esac

    if (( $(date +%s) >= deadline )); then
        echo "ERROR: timeout (${TIMEOUT}s) waiting for PR #$PR to reach terminal state" >&2
        exit 1
    fi
    sleep "$INTERVAL"
done
