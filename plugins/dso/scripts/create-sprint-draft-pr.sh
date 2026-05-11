#!/usr/bin/env bash
# create-sprint-draft-pr.sh — Idempotent draft PR creator for sprint workflows.
#
# Usage:
#   SESSION_BRANCH=<branch> PRIMARY_TICKET_ID=<ticket> [EPIC_TITLE=<title>] \
#     create-sprint-draft-pr.sh
#
# Environment variables:
#   SESSION_BRANCH      — the sprint worktree branch name (required)
#   PRIMARY_TICKET_ID   — the epic/sprint ticket ID (required)
#   EPIC_TITLE          — optional human-readable epic title for PR title
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

# ── Create draft PR ──────────────────────────────────────────────────────────
pr_title="Sprint: ${EPIC_TITLE} (${PRIMARY_TICKET_ID})"
pr_body="Long-lived sprint draft PR. Epic: ${PRIMARY_TICKET_ID}."

pr_url="$(
    gh pr create \
        --draft \
        --base main \
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
