#!/usr/bin/env bash
# create-sprint-draft-pr.sh — Idempotent draft PR creator for sprint workflows.
#
# Usage:
#   SESSION_BRANCH=<branch> PRIMARY_TICKET_ID=<ticket> [EPIC_TITLE=<title>] \
#     create-sprint-draft-pr.sh
#
# Environment variables:
#   SESSION_BRANCH           — the sprint worktree branch name (required)
#   PRIMARY_TICKET_ID        — the epic/sprint ticket ID (required)
#   EPIC_TITLE               — optional human-readable epic title for PR title
#   DRAFT_PR_TITLE_PREFIX    — PR title prefix (default: Sprint:)
#   DRAFT_PR_BODY_TEMPLATE   — PR body template; {{PRIMARY_TICKET_ID}} is interpolated
#                              (default: "Long-lived sprint draft PR. Epic: {{PRIMARY_TICKET_ID}}.")
#
# Exit codes:
#   0 — PR exists (or was just created)
#   1 — required env var missing, or gh pr create failed
#
# Idempotency:
#   If a draft PR already exists for SESSION_BRANCH against main, prints
#   the existing URL and exits 0 without creating a second PR.
#   If a non-draft (open) PR already exists, exits 0 without interference.

set -uo pipefail

# ── Validate required env vars ───────────────────────────────────────────────
if [[ -z "${SESSION_BRANCH:-}" ]]; then
    echo "ERROR: SESSION_BRANCH env var is required" >&2
    exit 1
fi

if [[ -z "${PRIMARY_TICKET_ID:-}" ]]; then
    echo "ERROR: PRIMARY_TICKET_ID env var is required" >&2
    exit 1
fi

EPIC_TITLE="${EPIC_TITLE:-sprint}"
DRAFT_PR_TITLE_PREFIX="${DRAFT_PR_TITLE_PREFIX:-Sprint:}"
_DEFAULT_BODY='Long-lived sprint draft PR. Epic: {{PRIMARY_TICKET_ID}}.'
DRAFT_PR_BODY_TEMPLATE="${DRAFT_PR_BODY_TEMPLATE:-$_DEFAULT_BODY}"

# ── Check for existing open PR on this branch ────────────────────────────────
existing_draft_url="$(
    gh pr list \
        --head "$SESSION_BRANCH" \
        --state open \
        --json url,isDraft,number \
        --jq 'map(select(.isDraft == true))[0].url // empty' \
    2>/dev/null
)"

if [[ -n "$existing_draft_url" ]]; then
    # Idempotent reuse — draft PR already exists
    echo "$existing_draft_url"
    exit 0
fi

# Check for any non-draft open PR (don't interfere)
existing_any_url="$(
    gh pr list \
        --head "$SESSION_BRANCH" \
        --state open \
        --json url,isDraft,number \
        --jq '.[0].url // empty' \
    2>/dev/null
)"

if [[ -n "$existing_any_url" ]]; then
    # Non-draft PR exists — exit 0 without creating anything
    echo "$existing_any_url"
    exit 0
fi

# ── Sentinel-commit bootstrap (zero-divergence case) ─────────────────────────
# `gh pr create` requires at least one commit between base and head. On a fresh
# session worktree at the same SHA as main, we open the umbrella PR by writing
# a single empty sentinel commit with a DSO-Sentinel: trailer + [skip ci]. The
# trailer makes the commit greppable for later cleanup; [skip ci] prevents CI
# runs on an epic with no real changes yet. Convergent pattern across Kubernetes
# feature branches, git-flow release branches, and peter-evans/create-pull-request.
# F-05: resolve default branch (master/develop/trunk-aware).
_SCRIPT_DIR_FOR_RESOLVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$_SCRIPT_DIR_FOR_RESOLVER/resolve-default-branch.sh" ]]; then
    _DEFAULT_BRANCH=$(bash "$_SCRIPT_DIR_FOR_RESOLVER/resolve-default-branch.sh" --no-warn 2>/dev/null || echo "main")
else
    _DEFAULT_BRANCH="main"
fi
: "${_DEFAULT_BRANCH:=main}"
_divergence="$(git rev-list --count "${_DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo "0")"
if [[ "$_divergence" == "0" ]]; then
    # Bypass the session-merge-only pre-commit hook for this single commit.
    # The hook accepts DSO_SPRINT_ACTIVE=0 + non-empty BYPASS_REASON; we use a
    # reason string that is greppable in audit logs and tied to this purpose.
    DSO_SPRINT_ACTIVE=0 \
    DSO_SPRINT_ACTIVE_BYPASS_REASON="epic-bootstrap-sentinel" \
    git commit --quiet --allow-empty \
        -m "chore(${PRIMARY_TICKET_ID}): open umbrella PR [skip ci]" \
        -m "DSO-Sentinel: epic-bootstrap" \
    || {
        echo "ERROR: sentinel commit failed — cannot open umbrella PR on a zero-divergence branch" >&2
        exit 1
    }
    # Push the sentinel so `gh pr create --head` finds it on origin.
    git push -u origin "$SESSION_BRANCH" --quiet 2>/dev/null || true
fi

# ── Create draft PR ──────────────────────────────────────────────────────────
pr_title="${DRAFT_PR_TITLE_PREFIX} ${EPIC_TITLE} (${PRIMARY_TICKET_ID})"
pr_body="${DRAFT_PR_BODY_TEMPLATE//\{\{PRIMARY_TICKET_ID\}\}/$PRIMARY_TICKET_ID}"

pr_url="$(
    gh pr create \
        --draft \
        --base "$_DEFAULT_BRANCH" \
        --head "$SESSION_BRANCH" \
        --title "$pr_title" \
        --body "$pr_body" \
    2>&1
)"
exit_code=$?

if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: gh pr create failed: $pr_url" >&2
    exit 1
fi

echo "$pr_url"
exit 0
