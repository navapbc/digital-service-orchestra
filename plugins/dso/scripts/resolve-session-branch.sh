#!/usr/bin/env bash
# resolve-session-branch.sh
#
# Resolves the current sprint session branch via a 3-step fallback:
#   1. gh pr view --json headRefName  (current PR's head branch)
#   2. gh api repos/{owner}/{repo}/actions/variables/SPRINT_SESSION_ID (repo var)
#   3. Fail with non-zero exit and actionable error message
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   resolve-session-branch.sh
#
# ── Environment / overrides ───────────────────────────────────────────────────
#   GH_PR_VIEW_OVERRIDE            Override step 1 output (for test isolation)
#   GH_API_SPRINT_SESSION_OVERRIDE Override step 2 output (for test isolation)
#
# ── Exit codes ────────────────────────────────────────────────────────────────
#   0  = success (branch name printed to stdout)
#   1  = SESSION_BRANCH could not be resolved; actionable error on stderr

set -euo pipefail

# ── Step 1: gh pr view headRefName ────────────────────────────────────────────
_step1_reason="not attempted"

if [[ -n "${GH_PR_VIEW_OVERRIDE:-}" ]]; then
    branch="$GH_PR_VIEW_OVERRIDE"
    if [[ -n "$branch" ]]; then
        echo "$branch"
        exit 0
    fi
    _step1_reason="GH_PR_VIEW_OVERRIDE was empty"
else
    _pr_json="$(gh pr view --json headRefName 2>/dev/null)" || true
    if [[ -n "$_pr_json" ]]; then
        branch="$(echo "$_pr_json" | jq -r '.headRefName // empty' 2>/dev/null)" || true
        if [[ -n "$branch" ]]; then
            echo "$branch"
            exit 0
        fi
        _step1_reason="gh pr view returned JSON but headRefName was empty"
    else
        _step1_reason="gh pr view returned empty output or failed"
    fi
fi

# ── Step 2: gh api SPRINT_SESSION_ID repo variable ────────────────────────────
_step2_reason="not attempted"

if [[ -n "${GH_API_SPRINT_SESSION_OVERRIDE:-}" ]]; then
    branch="$GH_API_SPRINT_SESSION_OVERRIDE"
    if [[ -n "$branch" ]]; then
        echo "$branch"
        exit 0
    fi
    _step2_reason="GH_API_SPRINT_SESSION_OVERRIDE was empty"
else
    # Resolve owner/repo from git remote (avoid calling gh here to keep mock-friendly)
    _origin="$(git remote get-url origin 2>/dev/null)" || true
    _repo="$(echo "$_origin" | sed -E 's|.*[:/]([^/.]+/[^/.]+)(\.git)?$|\1|')" || true

    if [[ -n "$_repo" ]]; then
        _api_json="$(gh api "repos/${_repo}/actions/variables/SPRINT_SESSION_ID" 2>/dev/null)" || true
        if [[ -n "$_api_json" ]]; then
            branch="$(echo "$_api_json" | jq -r '.value // empty' 2>/dev/null)" || true
            if [[ -n "$branch" ]]; then
                echo "$branch"
                exit 0
            fi
            _step2_reason="API returned JSON but value was empty"
        else
            _step2_reason="SPRINT_SESSION_ID variable not set or API failed"
        fi
    else
        _step2_reason="could not resolve owner/repo from git remote"
    fi
fi

# ── Step 3: fail-fast with actionable error ────────────────────────────────────
cat >&2 << EOF
ERROR: SESSION_BRANCH could not be resolved — ensure sprint Phase A completed.

  Step 1 (gh pr view headRefName): ${_step1_reason}
  Step 2 (SPRINT_SESSION_ID repo variable): ${_step2_reason}

To fix: re-run sprint Phase A, or manually set the SPRINT_SESSION_ID Actions
variable in your repository settings to the current session branch name.
EOF

exit 1
