#!/usr/bin/env bash
# resolve-per-branch-review-base.sh
#
# Resolves the diff base for per-branch-review.yml's scoped review. Bug
# 3914-0848-faad-4f6a: relying solely on SPRINT_SESSION_ID is brittle (the
# variable can drift, or stale across sessions). The PR's actual base is
# authoritative when available. This script implements the three-stage
# resolution chain so it can be unit-tested behaviorally.
#
# Resolution order:
#   1. Open PR for $BRANCH_NAME → use its baseRefName (authoritative)
#   2. $SPRINT_SESSION_ID → legacy sprint-driven fallback
#   3. "main" → always-safe final fallback
#
# Plus: existence validation. If the resolved base does not exist on origin,
# downgrade to "main" so the workflow never bails on a stale reference.
#
# Inputs (env vars):
#   BRANCH_NAME         — the head branch whose review scope we're resolving.
#                         Defaults to $GITHUB_REF_NAME, then `git branch --show-current`.
#   SPRINT_SESSION_ID   — repo-variable fallback (default: empty).
#   GH_TOKEN            — for gh auth in CI (when invoked from a workflow).
#   DSO_RESOLVE_PR_OVERRIDE — test hook: a path to a stub `gh` binary directory
#                             (prepended to PATH so unit tests can mock the
#                             PR-base lookup deterministically).
#   DSO_RESOLVE_LSREMOTE_OVERRIDE — test hook: a path to a stub `git` binary
#                                   directory used for the existence check.
#
# Output: prints the resolved BASE_REF to stdout. Always exit 0.

set -uo pipefail

# Allow tests to inject stub binaries by prepending a directory to PATH.
if [[ -n "${DSO_RESOLVE_PR_OVERRIDE:-}" ]]; then
    PATH="$DSO_RESOLVE_PR_OVERRIDE:$PATH"
fi

BRANCH_NAME="${BRANCH_NAME:-${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null || echo "")}}"
SPRINT_SESSION_ID="${SPRINT_SESSION_ID:-}"

BASE_REF=""

# Stage 1: PR base via gh — authoritative when an open PR exists.
if [[ -n "$BRANCH_NAME" ]] && command -v gh >/dev/null 2>&1; then
    BASE_REF="$(gh pr list --head "$BRANCH_NAME" --state open --json baseRefName --jq '.[0].baseRefName // empty' 2>/dev/null || true)"
fi

# Stage 2: SPRINT_SESSION_ID repo variable — sprint-driven fallback.
if [[ -z "$BASE_REF" && -n "$SPRINT_SESSION_ID" ]]; then
    BASE_REF="$SPRINT_SESSION_ID"
fi

# Stage 3: always-safe final fallback.
if [[ -z "$BASE_REF" ]]; then
    BASE_REF="main"
fi

# Existence validation: a stale reference (deleted branch, typo) must not
# silently produce a wrong-scoped review. Downgrade to main if not found.
if [[ "$BASE_REF" != "main" ]]; then
    if ! git ls-remote --exit-code --heads origin "$BASE_REF" >/dev/null 2>&1; then
        BASE_REF="main"
    fi
fi

echo "$BASE_REF"
