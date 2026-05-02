#!/usr/bin/env bash
# merge-to-main-pr.sh — PR merge mode (skeleton).
#
# Skeleton implementation that satisfies:
#   * gh CLI version gate (requires >= 2.0.0 for GraphQL features used by
#     downstream PR-create logic in Task 3 — DD7).
#   * Duplicate-PR guard: refuse to run when an open PR already exists for
#     the current branch (DD4).
#   * CONFLICT_DATA contract parity with merge-to-main-direct.sh: when the
#     (placeholder) merge phase fails, emit the same JSON line via the
#     shared _emit_conflict_data helper in merge-helpers.sh (DD6 — PR side).
#
# Full PR-creation flow (gh pr create, auto-merge enable, status polling)
# lands in Task 3. This skeleton makes the T1 dispatcher routing and PR
# CONFLICT_DATA tests turn GREEN without committing to that flow yet.
#
# Usage: merge-to-main-pr.sh [--resume|--help]
# Exit codes: 0=success, 1=error
set -euo pipefail

# --- CLI: --help (early exit before any context checks) ---
for _arg in "$@"; do
    if [[ "$_arg" == "--help" ]]; then
        cat <<'USAGE'
Usage: merge-to-main-pr.sh [--resume|--help]

  --resume        Resume from last incomplete phase (state file in /tmp).
  --help          Print this usage message and exit.

  (no args)       Run all phases sequentially.

PR mode creates a pull request against main, enables auto-merge, and waits
for required status checks to pass. Requires gh CLI 2.0.0+ for GraphQL.
USAGE
        exit 0
    fi
done

# --- Required env vars (set by the dispatcher) ---
: "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set}"
: "${MERGE_STRATEGY:?MERGE_STRATEGY must be set (expected: pr)}"

# --- Resolve repo root (best-effort; PR mode can run outside a git repo for
# certain failure paths in skeleton form, but most production paths require it). ---
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [[ -n "$REPO_ROOT" ]]; then
    cd "$REPO_ROOT"
fi

# --- Resolve current branch (best-effort) ---
# Falls back to "unknown" outside a git repo so downstream helpers (e.g.,
# _emit_conflict_data, _state_init) still receive a non-empty value.
BRANCH=$(git branch --show-current 2>/dev/null || true)
BRANCH="${BRANCH:-unknown}"

# --- Load merge utility helpers (state file, lock, recovery, CONFLICT_DATA) ---
# shellcheck source=${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-helpers.sh
_MERGE_HELPERS_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-helpers.sh"
if [[ -f "$_MERGE_HELPERS_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$_MERGE_HELPERS_LIB"
fi

# --- gh CLI version gate (DD7) ---
# Parse `gh --version` first line: "gh version 2.40.1 (2024-...)" → "2.40.1".
# Compare against minimum 2.0.0 via `sort -V`. On too-old / missing gh: exit 1.
_check_gh_version() {
    local _min="2.0.0"
    local _found
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: gh CLI not found on PATH (required for PR-mode merge)" >&2
        return 1
    fi
    _found=$(gh --version 2>/dev/null | awk 'NR==1 {print $3; exit}')
    if [[ -z "$_found" ]]; then
        echo "ERROR: gh CLI 2.0.0+ required for PR-mode merge (could not parse \`gh --version\` output)" >&2
        return 1
    fi
    # `printf "%s\n%s\n" "$_min" "$_found" | sort -V | head -n1` → smaller of the two.
    # If the smaller is _min (or both equal), _found >= _min.
    local _smallest
    _smallest=$(printf '%s\n%s\n' "$_min" "$_found" | sort -V | head -n1)
    if [[ "$_smallest" != "$_min" ]] || [[ "$_found" == "$_smallest" && "$_found" != "$_min" ]]; then
        # _found is the smaller → too old
        echo "ERROR: gh CLI 2.0.0+ required for PR-mode merge (found $_found)" >&2
        return 1
    fi
    return 0
}

if ! _check_gh_version; then
    exit 1
fi

# --- Duplicate-PR guard (DD4) ---
# `gh pr list --head $BRANCH --state open --json number,url --jq '.[0].url'`.
# Non-empty result → an open PR already exists for this branch → exit non-zero.
# Best-effort: if gh fails (no auth, no remote, etc.), proceed — the downstream
# PR-create call in Task 3 will surface the underlying error with full context.
_check_duplicate_pr() {
    local _existing
    _existing=$(gh pr list --head "$BRANCH" --state open --json number,url --jq '.[0].url' 2>/dev/null || true)
    if [[ -n "$_existing" ]]; then
        echo "ERROR: open PR already exists for branch $BRANCH: $_existing" >&2
        return 1
    fi
    return 0
}

if ! _check_duplicate_pr; then
    exit 1
fi

# --- Initialize state file (best-effort; requires BRANCH set above) ---
if type _state_init >/dev/null 2>&1; then
    _state_init 2>/dev/null || true
fi

# --- State writer: persist PR url + number into the state file ---
# Best-effort; mirrors merge-helpers.sh's other _state_* writers.
_state_write_pr_meta() {
    local _pr_url="$1"
    local _pr_number="$2"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    PR_URL="$_pr_url" PR_NUMBER="$_pr_number" SF="$_sf" python3 -c "
import json, os
sf = os.environ['SF']
with open(sf) as f:
    d = json.load(f)
d['pr_url'] = os.environ.get('PR_URL', '')
try:
    d['pr_number'] = int(os.environ.get('PR_NUMBER', '0'))
except Exception:
    d['pr_number'] = os.environ.get('PR_NUMBER', '')
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

# --- _phase_merge (PR mode): push branch, create PR, queue auto-merge ---
# DD1: gh pr create + gh pr merge --auto --merge
# DD6: emit CONFLICT_DATA when gh reports mergeable=CONFLICTING
#
# Steps:
#   1. git push -u origin "$BRANCH"           — publish branch
#   2. gh pr create --base main --head "$BRANCH" --title <derived> --body <auto>
#      → capture PR url + number
#   3. Persist pr_url, pr_number into state file
#   4. gh pr view <num> --json mergeable      — detect CONFLICTING up-front
#   5. gh pr merge <num> --auto --merge       — queue auto-merge
#      → on "auto-merge not allowed" stderr: print clear error, exit 1
#
# Returns 0 on success, 1 on conflict / auto-merge-disabled / unrecoverable error.
# CONFLICT_DATA emission is performed by the caller (top-level error handler
# below) so the contract surface is identical to direct mode.
_phase_merge() {
    if type _state_write_phase >/dev/null 2>&1; then
        _state_write_phase "merge" 2>/dev/null || true
    fi

    # --- 1. Publish branch ---
    if ! git push -u origin "$BRANCH" 2>&1; then
        echo "ERROR: git push -u origin $BRANCH failed" >&2
        return 1
    fi

    # --- 2. Derive PR title from last meaningful commit subject ---
    local _title
    _title=$(git log -1 --pretty=%s 2>/dev/null || echo "Merge $BRANCH")
    if [[ -z "$_title" ]]; then
        _title="Merge $BRANCH"
    fi

    local _body
    _body="Auto-generated PR for branch \`$BRANCH\` (created by merge-to-main-pr.sh)."

    # --- 3. Create the PR ---
    local _pr_url _pr_create_rc=0
    _pr_url=$(gh pr create --base main --head "$BRANCH" \
                          --title "$_title" --body "$_body" 2>&1) || _pr_create_rc=$?
    if [[ "$_pr_create_rc" -ne 0 ]]; then
        echo "ERROR: gh pr create failed: $_pr_url" >&2
        # _pr_url may contain the error text — still return 1 so caller emits
        # CONFLICT_DATA (best-effort) for upstream orchestrators.
        return 1
    fi

    # gh pr create may print extra log lines before the URL; extract the
    # last line that looks like a PR url.
    local _final_url
    _final_url=$(echo "$_pr_url" | grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' | tail -n1)
    if [[ -z "$_final_url" ]]; then
        # Fallback: trust the entire stdout as the URL (some gh versions emit
        # only the URL with no surrounding text).
        _final_url=$(echo "$_pr_url" | tail -n1 | tr -d '[:space:]')
    fi

    local _pr_number
    _pr_number=$(echo "$_final_url" | grep -Eo '/pull/[0-9]+' | grep -Eo '[0-9]+$')
    if [[ -z "$_pr_number" ]]; then
        echo "ERROR: could not parse PR number from gh pr create output: $_pr_url" >&2
        return 1
    fi

    # --- 4. Persist PR url + number to state file (best-effort) ---
    _state_write_pr_meta "$_final_url" "$_pr_number" 2>/dev/null || true

    echo "INFO: Created PR #${_pr_number}: $_final_url"

    # --- 5. Detect CONFLICTING up-front via `gh pr view --json mergeable` ---
    # If GitHub reports the PR as CONFLICTING, return 1 so the caller emits
    # CONFLICT_DATA. We do not enqueue auto-merge for a known-conflicting PR.
    local _mergeable_json _mergeable
    _mergeable_json=$(gh pr view "$_pr_number" --json mergeable 2>/dev/null || true)
    _mergeable=$(echo "$_mergeable_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('mergeable', ''))
except Exception:
    print('')
" 2>/dev/null || true)

    if [[ "$_mergeable" == "CONFLICTING" ]]; then
        echo "ERROR: PR #${_pr_number} is CONFLICTING — cannot enqueue auto-merge" >&2
        return 1
    fi

    # --- 6. Queue auto-merge (--merge to match direct mode's --no-ff semantics) ---
    local _merge_out _merge_rc=0
    _merge_out=$(gh pr merge "$_pr_number" --auto --merge 2>&1) || _merge_rc=$?
    if [[ "$_merge_rc" -ne 0 ]]; then
        # Detect the "auto-merge not allowed" repo-setting case so the user
        # gets actionable guidance (DD1 acceptance criterion).
        if echo "$_merge_out" | grep -qiE "auto.?merge.*(not allowed|disabled|cannot be enabled)"; then
            echo "ERROR: GitHub auto-merge is disabled for this repository." >&2
            echo "       Enable it under Settings → General → 'Allow auto-merge', then re-run with --resume." >&2
            echo "       (gh stderr: $_merge_out)" >&2
        else
            echo "ERROR: gh pr merge ${_pr_number} --auto --merge failed: $_merge_out" >&2
        fi
        return 1
    fi

    if type _state_mark_complete >/dev/null 2>&1; then
        _state_mark_complete "merge" 2>/dev/null || true
    fi

    echo "INFO: Auto-merge queued for PR #${_pr_number}."
    return 0
}

# --- Run merge phase; on failure, emit CONFLICT_DATA contract line ---
if ! _phase_merge; then
    if type _emit_conflict_data >/dev/null 2>&1; then
        _emit_conflict_data "$BRANCH" "main" "pr-auto-merge"
    fi
    exit 1
fi

# Skeleton end — version_bump → push → archive → ci_trigger land in later tasks.
exit 0
