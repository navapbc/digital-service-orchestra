#!/usr/bin/env bash
# provision-ruleset.sh
# Provision a GitHub branch protection ruleset for DSO CI enforcement.
#
# Usage:
#   provision-ruleset.sh [--repo <owner/repo>] [--checks-file <path>] \
#                        [--non-interactive] [--dry-run]
#
# Environment:
#   DSO_DRY_RUN=1   — print payloads and gh commands; do not execute them
#
# Exit codes:
#   0 — success (or dry-run complete)
#   1 — pre-flight failure or runtime error

set -euo pipefail

# ── Self-location ─────────────────────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO=""
CHECKS_FILE=""
NON_INTERACTIVE=0
DRY_RUN="${DSO_DRY_RUN:-0}"

# Resolve repo root (git root relative to script location or cwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null \
  || git rev-parse --show-toplevel 2>/dev/null \
  || echo "")

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --checks-file)
      CHECKS_FILE="$2"
      shift 2
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Default checks file relative to repo root
if [[ -z "$CHECKS_FILE" ]]; then
  if [[ -n "$REPO_ROOT" ]]; then
    CHECKS_FILE="$REPO_ROOT/.github/required-checks.txt"
  else
    CHECKS_FILE=".github/required-checks.txt"
  fi
fi

# ── Pre-flight: verify gh CLI ─────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
  cat <<'EOF'
# Manual GitHub Ruleset Setup Guide

The `gh` CLI was not found in PATH. To provision the DSO CI enforcement
ruleset manually, follow these steps:

## 1. Install the GitHub CLI

  https://cli.github.com/

## 2. Authenticate

  gh auth login

## 3. Create the branch protection ruleset via the GitHub UI

  1. Navigate to your repository → Settings → Rules → Rulesets.
  2. Click "New ruleset" → "New branch ruleset".
  3. Set:
     - Name: DSO CI Enforcement
     - Enforcement status: Active
     - Target branches: Default branch (main)
  4. Under "Rules", enable:
     - Restrict deletions
     - Block force pushes
     - Require a pull request before merging
     - Require status checks to pass
  5. Add required status checks from .github/required-checks.txt.
  6. Save.

## 4. Enable auto-merge

  gh repo edit --enable-auto-merge

EOF
  exit 1
fi

# Verify auth scope (soft check — warn but continue)
if ! gh auth status >/dev/null 2>&1; then
  echo "WARNING: gh auth status check failed — token may lack admin scope." >&2
fi

# ── Pre-flight: verify jq ─────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found in PATH. Install jq and retry." >&2
  exit 1
fi

# ── Resolve default branch ────────────────────────────────────────────────────
# Auto-detect from the git remote when a repo is known; fall back to "main".
# Resolved later after REPO is confirmed (see confirm-repo section).
DEFAULT_BRANCH="main"

# ── Read check names from file ────────────────────────────────────────────────
if [[ ! -f "$CHECKS_FILE" ]]; then
  echo "ERROR: checks file not found: $CHECKS_FILE" >&2
  exit 1
fi

# Build JSON array of status check contexts using jq for safe handling of
# check names that may contain JSON-special characters (quotes, backslashes, etc.)
STATUS_CONTEXTS_JSON=$(
  grep -v '^\s*#' "$CHECKS_FILE" | grep -v '^\s*$' | \
  jq -R '{context: .}' | jq -s '.'
)

if [[ "$STATUS_CONTEXTS_JSON" == "[]" ]] || [[ -z "$STATUS_CONTEXTS_JSON" ]]; then
  echo "ERROR: No check contexts found in '$CHECKS_FILE'. Check file must have at least one non-comment entry." >&2
  exit 1
fi

# ── Build ruleset JSON payload ────────────────────────────────────────────────
# bypass_actors actor_id 5 = GitHub RepositoryRole "Admin" (standard ID on github.com)
PAYLOAD_JSON=$(cat <<EOF
{
  "name": "DSO CI Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/${DEFAULT_BRANCH}"],
      "exclude": []
    }
  },
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ],
  "rules": [
    {"type": "non_fast_forward"},
    {"type": "deletion"},
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": ${STATUS_CONTEXTS_JSON}
      }
    }
  ]
}
EOF
)

# ── Dry-run mode ──────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  echo "=== DSO_DRY_RUN=1: No API calls will be made ==="
  echo ""
  echo "--- Ruleset JSON payload ---"
  echo "$PAYLOAD_JSON"
  echo ""
  if [[ -n "$REPO" ]]; then
    echo "--- gh api invocation (not executed) ---"
    echo "gh api --method POST /repos/${REPO}/rulesets --input <(echo '\$payload_json')"
    echo ""
    echo "--- gh repo edit invocation (not executed) ---"
    echo "gh repo edit ${REPO} --enable-auto-merge"
  else
    echo "--- gh api invocation (not executed) ---"
    echo "gh api --method POST /repos/{owner}/{repo}/rulesets --input <(echo '\$payload_json')"
    echo ""
    echo "--- gh repo edit invocation (not executed) ---"
    echo "gh repo edit --enable-auto-merge"
  fi
  exit 0
fi

# ── Confirm repo ──────────────────────────────────────────────────────────────
if [[ -z "$REPO" ]]; then
  # Attempt to detect from git remote
  REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
  if [[ -z "$REPO" ]]; then
    echo "ERROR: --repo <owner/repo> is required (or run from inside a git repo with a GitHub remote)." >&2
    exit 1
  fi
fi

# Auto-detect default branch now that REPO is confirmed
_DETECTED_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo "")
if [[ -n "$_DETECTED_BRANCH" ]]; then
  DEFAULT_BRANCH="$_DETECTED_BRANCH"
fi

# ── Interactive confirmation ──────────────────────────────────────────────────
if [[ "$NON_INTERACTIVE" -ne 1 ]]; then
  echo "About to provision ruleset 'DSO CI Enforcement' on repo: $REPO"
  echo "Target branch: $DEFAULT_BRANCH"
  printf "Proceed? [y/N] "
  read -r confirmation
  case "$confirmation" in
    y|Y|yes|YES) ;;
    *)
      echo "Aborted." >&2
      exit 1
      ;;
  esac
fi

# ── Create ruleset via GitHub API ─────────────────────────────────────────────
TMPFILE=$(mktemp /tmp/provision-ruleset-payload.XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

echo "$PAYLOAD_JSON" > "$TMPFILE"

echo "Creating ruleset on $REPO ..."
RULESET_RESPONSE=$(gh api --method POST "/repos/${REPO}/rulesets" --input "$TMPFILE")
RULESET_ID=$(echo "$RULESET_RESPONSE" | jq -r '.id')

# ── Enable auto-merge ─────────────────────────────────────────────────────────
echo "Enabling auto-merge on $REPO ..."
gh repo edit "$REPO" --enable-auto-merge

# ── Success summary ───────────────────────────────────────────────────────────
echo ""
echo "=== DSO CI Enforcement Ruleset Provisioned ==="
echo "Repository:  $REPO"
echo "Branch:      $DEFAULT_BRANCH"
echo "Ruleset ID:  ${RULESET_ID:-unknown}"
echo "Auto-merge:  enabled"
