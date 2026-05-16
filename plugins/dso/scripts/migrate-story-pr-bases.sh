#!/usr/bin/env bash
# migrate-story-pr-bases.sh
#
# Migrates story/* PRs targeting main to target the current session branch instead.
#
# Steps:
#   1. Resolve the session branch via resolve-session-branch.sh (or DSO_RESOLVE_SESSION_BRANCH env var override)
#   2. List story/* PRs currently targeting main
#   3. For each such PR, PATCH its base to the session branch
#   4. Trigger per-branch-review.yml workflow run for each migrated PR
#   5. Note TrackerDefenseStore cache invalidation for each migrated PR
#   6. Skip PRs already targeting the session branch (idempotent)
#
# Environment variables:
#   DSO_RESOLVE_SESSION_BRANCH  Path to resolve-session-branch.sh override (for test isolation)
#   DSO_GH_REPO                 Owner/repo override (e.g. "navapbc/digital-service-orchestra")
#
# Usage:
#   migrate-story-pr-bases.sh

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Step 1: Resolve session branch ────────────────────────────────────────────
_resolve_script="${DSO_RESOLVE_SESSION_BRANCH:-"$_SCRIPT_DIR/resolve-session-branch.sh"}"

session_branch=""
if ! session_branch="$("$_resolve_script" 2>&1)"; then
    echo "ERROR: Failed to resolve session branch." >&2
    echo "$session_branch" >&2
    exit 1
fi

if [[ -z "$session_branch" ]]; then
    echo "ERROR: Session branch resolved to empty string." >&2
    exit 1
fi

# ── Step 2: Detect repo (owner/repo) ─────────────────────────────────────────
if [[ -n "${DSO_GH_REPO:-}" ]]; then
    _repo="$DSO_GH_REPO"
else
    _repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
fi

# ── Step 3: List story/* PRs targeting main ───────────────────────────────────
_pr_json_raw="$(gh pr list --search 'base:main head:story/' \
    --json number,headRefName,baseRefName 2>/dev/null || true)"

# Parse JSON array — supports both real gh output (array) and mock output
# Count entries
_pr_count=0
if [[ -n "$_pr_json_raw" ]]; then
    _pr_count="$(echo "$_pr_json_raw" | jq '. | length' 2>/dev/null || echo 0)"
fi

if [[ "$_pr_count" -eq 0 ]]; then
    echo "No story/* PRs targeting main found."
    exit 0
fi

# ── Step 4: Process each PR ───────────────────────────────────────────────────
# Iterate by index over the JSON array
for _idx in $(seq 0 $((_pr_count - 1))); do
    pr_number="$(echo "$_pr_json_raw" | jq -r ".[$_idx].number")"
    head_ref="$(echo "$_pr_json_raw" | jq -r ".[$_idx].headRefName")"
    base_ref="$(echo "$_pr_json_raw" | jq -r ".[$_idx].baseRefName")"

    if [[ "$base_ref" == "$session_branch" ]]; then
        echo "Already targeting session branch: #${pr_number}"
        continue
    fi

    echo "Migrating PR #${pr_number} (${head_ref}): base ${base_ref} -> ${session_branch}"

    # PATCH the PR base to the session branch
    gh api --method PATCH "repos/${_repo}/pulls/${pr_number}" \
        -f base="${session_branch}" > /dev/null

    # Trigger per-branch-review workflow for the migrated PR
    gh workflow run per-branch-review.yml --ref "${head_ref}"

    # Note cache invalidation
    echo "NOTE: TrackerDefenseStore entries for PR #${pr_number} were written against base=main and are no longer valid. A fresh per-branch-review run has been triggered."
done
