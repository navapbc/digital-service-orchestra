#!/usr/bin/env bash
# hook-boundary: enforcement
# hooks/pre-commit-ticket-gate.sh
# git commit-msg hook: blocks commits lacking a valid v3 ticket ID in the message.
#
# DESIGN:
#   This hook runs at the commit-msg stage, receiving the commit message file
#   path as $1 (standard git commit-msg hook convention). It checks that the
#   commit message contains at least one valid v3 ticket ID (XXXX-XXXX hex
#   format) that exists in the event-sourced tracker.
#
# LOGIC (in order):
#   1. Fail-open on timeout (SIGTERM/SIGURG).
#   2. Read commit message from $1 (or COMMIT_MSG_FILE_OVERRIDE for tests).
#   3. Merge commit exemption: if MERGE_HEAD exists → exit 0.
#   4. Get staged files via git diff --cached --name-only.
#   5. Load allowlist from review-gate-allowlist.conf (via deps.sh).
#   6. If ALL staged files match allowlist → exit 0 (no ticket needed).
#   7. Graceful degradation: if tracker not mounted → warn → exit 0.
#   8. Extract ticket IDs matching [a-z0-9]{4}-[a-z0-9]{4} from message.
#   9. For each ID: check dir exists + CREATE event file present in tracker.
#  10. If any valid ID found → exit 0.
#  11. Otherwise → exit 1 with format hint and ticket creation pointer.
#
# INSTALL:
#   Registered in .pre-commit-config.yaml as a commit-msg stage local hook.
#
# ENVIRONMENT:
#   COMMIT_MSG_FILE_OVERRIDE  — path to commit message file (used in tests)
#   TICKET_TRACKER_OVERRIDE   — path to tracker dir (used in tests)
#   CONF_OVERRIDE             — path to allowlist conf (used in tests)

set -uo pipefail

# ── Fail-open on timeout ─────────────────────────────────────────────────────
# pre-commit sends SIGTERM after timeout; Claude Code tool timeout sends SIGURG.
# A gate timeout is infrastructure failure — fail open so commits aren't blocked.
# shellcheck disable=SC2329  # Pre-existing: function invoked indirectly via trap SIGTERM/SIGURG
_fail_open_on_timeout() {
    echo "pre-commit-ticket-gate: WARNING: timed out — failing open (commit allowed)" >&2
    exit 0
}
trap _fail_open_on_timeout TERM URG

# ── Locate hook and plugin directories ──────────────────────────────────────
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared dependency library (provides _load_allowlist_patterns, _allowlist_to_grep_regex, get_artifacts_dir)
source "$HOOK_DIR/lib/deps.sh"

# Source shared merge/rebase state library (provides ms_is_merge_in_progress, etc.)
source "$HOOK_DIR/lib/merge-state.sh"

# ── Read commit message ──────────────────────────────────────────────────────
# Supports COMMIT_MSG_FILE_OVERRIDE for test injection; falls back to $1 (git standard).
_COMMIT_MSG_FILE="${COMMIT_MSG_FILE_OVERRIDE:-${1:-}}"
if [[ -z "$_COMMIT_MSG_FILE" || ! -f "$_COMMIT_MSG_FILE" ]]; then
    # No commit message file available — fail open (do not block)
    exit 0
fi
COMMIT_MSG=$(cat "$_COMMIT_MSG_FILE" 2>/dev/null || echo "")

# ── Merge commit exemption ────────────────────────────────────────────────────
# When a merge is in progress (MERGE_HEAD exists and is not self-referencing),
# exit 0 unconditionally. Uses ms_is_merge_in_progress from merge-state.sh
# which includes the MERGE_HEAD==HEAD guard to prevent bypass via fake MERGE_HEAD.
if ms_is_merge_in_progress; then
    exit 0
fi

# ── Get staged files ─────────────────────────────────────────────────────────
STAGED_FILES=()
_staged_output=$(git diff --cached --name-only 2>/dev/null || true)
if [[ -n "$_staged_output" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        STAGED_FILES+=("$f")
    done <<< "$_staged_output"
fi

# No staged files → nothing to check
if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
    exit 0
fi

# ── Load allowlist patterns ───────────────────────────────────────────────────
ALLOWLIST_PATH="${CONF_OVERRIDE:-$HOOK_DIR/lib/review-gate-allowlist.conf}"
ALLOWLIST_PATTERNS=""
if [[ -f "$ALLOWLIST_PATH" ]]; then
    ALLOWLIST_PATTERNS=$(_load_allowlist_patterns "$ALLOWLIST_PATH" 2>/dev/null || true)
fi

# Build a grep regex from the allowlist for fast file matching
NON_REVIEWABLE_REGEX=""
if [[ -n "$ALLOWLIST_PATTERNS" ]]; then
    while IFS= read -r _regex_line; do
        [[ -z "$_regex_line" ]] && continue
        if [[ -z "$NON_REVIEWABLE_REGEX" ]]; then
            NON_REVIEWABLE_REGEX="$_regex_line"
        else
            NON_REVIEWABLE_REGEX="${NON_REVIEWABLE_REGEX}|${_regex_line}"
        fi
    done <<< "$(_allowlist_to_grep_regex "$ALLOWLIST_PATTERNS")"
fi

# ── Check if all staged files are allowlisted ─────────────────────────────────
NON_ALLOWLISTED_FILES=()
if [[ -z "$NON_REVIEWABLE_REGEX" ]]; then
    # No allowlist loaded — everything requires a ticket (fail-safe)
    NON_ALLOWLISTED_FILES=("${STAGED_FILES[@]}")
else
    _non_allowlisted=$(printf '%s\n' "${STAGED_FILES[@]}" | grep -vE "$NON_REVIEWABLE_REGEX" 2>/dev/null || true)
    if [[ -n "$_non_allowlisted" ]]; then
        while IFS= read -r _classified_file; do
            [[ -n "$_classified_file" ]] && NON_ALLOWLISTED_FILES+=("$_classified_file")
        done <<< "$_non_allowlisted"
    fi
fi

# All staged files are allowlisted → no ticket needed
if [[ ${#NON_ALLOWLISTED_FILES[@]} -eq 0 ]]; then
    exit 0
fi

# ── Resolve tracker directory ─────────────────────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
TRACKER_DIR="${TICKET_TRACKER_OVERRIDE:-${REPO_ROOT}/.tickets-tracker}"

# Graceful degradation: if tracker is not mounted, warn and fail open
if [[ ! -d "$TRACKER_DIR" ]]; then
    echo "pre-commit-ticket-gate: WARNING: ticket tracker not mounted at ${TRACKER_DIR} — skipping ticket check" >&2
    exit 0
fi

# ── Extract v3 ticket IDs from commit message ─────────────────────────────────
# v3 format: four lowercase hex chars, dash, four lowercase hex chars: e.g. dso-78iq
TICKET_IDS=()
while IFS= read -r _matched_id; do
    [[ -n "$_matched_id" ]] && TICKET_IDS+=("$_matched_id")
done < <(echo "$COMMIT_MSG" | grep -oE '[a-z0-9]{4}-[a-z0-9]{4}' 2>/dev/null || true)

# ── Validate each extracted ticket ID ────────────────────────────────────────
TICKET_SHIM="${TICKET_SHIM_OVERRIDE:-${REPO_ROOT}/.claude/scripts/dso}"
# Performance note: shim call (~44ms per ticket) vs direct FS check (<1ms).
# Bounded by early-exit: returns as soon as any valid ticket ID is found.
# Correctness gain: ticket-exists.sh checks both CREATE and SNAPSHOT events.
for _id in "${TICKET_IDS[@]+"${TICKET_IDS[@]}"}"; do
    if TICKETS_TRACKER_DIR="$TRACKER_DIR" "$TICKET_SHIM" ticket exists "$_id" 2>/dev/null; then
        exit 0
    fi
done

# ── No valid ticket ID found → block commit ───────────────────────────────────
echo "" >&2
echo "BLOCKED: commit-msg ticket gate" >&2
echo "" >&2
echo "  Commit message must reference a valid v3 ticket ID." >&2
echo "  Expected format: XXXX-XXXX (hex, e.g. dso-78iq)" >&2
echo "" >&2
echo "  Your commit message:" >&2
echo "    ${COMMIT_MSG}" >&2
echo "" >&2
echo "  To create a ticket: ticket create task \"<description>\"" >&2
echo "  Then add the ticket ID to your commit message." >&2
echo "" >&2
exit 1
