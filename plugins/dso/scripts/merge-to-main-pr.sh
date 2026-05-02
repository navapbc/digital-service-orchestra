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

# --- Placeholder _phase_merge (full implementation in Task 3) ---
# Returns 1 to exercise the CONFLICT_DATA emission path. Task 3 will replace
# this with the real `gh pr create` + auto-merge flow.
_phase_merge() {
    echo "INFO: PR-mode _phase_merge not yet implemented (Task 3) — emitting placeholder failure" >&2
    return 1
}

# --- Run merge phase; on failure, emit CONFLICT_DATA contract line ---
if ! _phase_merge; then
    if type _emit_conflict_data >/dev/null 2>&1; then
        _emit_conflict_data "$BRANCH" "main" "pr-auto-merge"
    fi
    exit 1
fi

# Skeleton end — Task 3 fills in version_bump → push → archive → ci_trigger.
exit 0
