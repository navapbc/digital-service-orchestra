#!/usr/bin/env bash
# migrate-story-pr-bases.sh
#
# Migrates story/* PRs targeting main to target the current session branch instead.
#
# Steps:
#   1. Resolve the session branch via resolve-session-branch.sh (or DSO_RESOLVE_SESSION_BRANCH env var override)
#   2. List story/* PRs currently targeting main
#   3. For each such PR, PATCH its base to the session branch
#   4. Note TrackerDefenseStore cache invalidation for each migrated PR
#   5. Skip PRs already targeting the session branch (idempotent)
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
    # jq-free (PR #140 retro-review): parse the nameWithOwner via python3
    # instead of `gh --jq`, matching the project's jq-free invariant
    # documented in the project's reviewer-delta-standard prompt.
    # Single-quoted heredoc on the python so bash does not expand $-tokens
    # inside the python source.
    _repo="$(gh repo view --json nameWithOwner 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("nameWithOwner", "") if isinstance(d, dict) else "")
' 2>/dev/null)"
fi

# ── Step 3: List story/* PRs targeting main ───────────────────────────────────
_pr_json_raw="$(gh pr list --search 'base:main head:story/' \
    --json number,headRefName,baseRefName 2>/dev/null || true)"

# Parse JSON array via python3 (jq-free, PR #140 retro-review).
# Emit "<number>\t<headRefName>\t<baseRefName>" per PR; iterate via read.
_pr_lines=""
if [[ -n "$_pr_json_raw" ]]; then
    _pr_lines="$(printf '%s' "$_pr_json_raw" | python3 -c '
import json, sys
try:
    arr = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for entry in (arr if isinstance(arr, list) else []):
    if not isinstance(entry, dict):
        continue
    print("\t".join([
        str(entry.get("number", "")),
        str(entry.get("headRefName", "")),
        str(entry.get("baseRefName", "")),
    ]))
' 2>/dev/null)"
fi

if [[ -z "$_pr_lines" ]]; then
    echo "No story/* PRs targeting main found."
    exit 0
fi

# ── Step 4: Process each PR ───────────────────────────────────────────────────
while IFS=$'\t' read -r pr_number head_ref base_ref; do
    [[ -z "$pr_number" ]] && continue

    if [[ "$base_ref" == "$session_branch" ]]; then
        echo "Already targeting session branch: #${pr_number}"
        continue
    fi

    echo "Migrating PR #${pr_number} (${head_ref}): base ${base_ref} -> ${session_branch}"

    # PATCH the PR base to the session branch
    gh api --method PATCH "repos/${_repo}/pulls/${pr_number}" \
        -f base="${session_branch}" > /dev/null

    # Note cache invalidation (per-branch-review.yml was removed in story 20d7-09d6;
    # ci.yml llm-review fires automatically when the PR targets main)
    echo "NOTE: TrackerDefenseStore entries for PR #${pr_number} were written against base=main and are no longer valid."
done <<< "$_pr_lines"
