#!/usr/bin/env bash
# provision-ruleset.sh
# Provision a GitHub branch protection ruleset for DSO CI enforcement.
#
# Usage:
#   provision-ruleset.sh [--repo <owner/repo>] [--checks-file <path>] \
#                        [--non-interactive] [--dry-run] \
#                        [--bypass-actor-policy=always|pull_request_only] \
#                        [--require-conversation-resolution=true|false] \
#                        [--request-copilot-review=true|false] \
#                        [--dismiss-stale-approvals-on-push=true|false] \
#                        [--required-approvals=N]
#
# Knob defaults (all preserve existing behavior):
#   --bypass-actor-policy=always
#   --require-conversation-resolution=false
#   --request-copilot-review=false
#   --dismiss-stale-approvals-on-push=false
#   --required-approvals=1
#
# Each flag accepts both "--flag=value" and "--flag value" forms. Boolean flags
# accept true/false/yes/no/1/0 (normalized to 0/1 internally).
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

# Named knobs (defaults preserve current hardcoded behavior)
BYPASS_ACTOR_POLICY="always"
REQUIRE_CONVERSATION_RESOLUTION=0
REQUEST_COPILOT_REVIEW=0
DISMISS_STALE_APPROVALS_ON_PUSH=0
REQUIRED_APPROVALS=1

# Resolve repo root (git root relative to script location or cwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null \
  || git rev-parse --show-toplevel 2>/dev/null \
  || echo "")

# ── Helpers ──────────────────────────────────────────────────────────────────
# Normalize a boolean string (true/false/yes/no/1/0) to "0" or "1".
# Exits 1 if the value is not a recognized boolean.
_normalize_bool() {
  local label="$1" raw="$2"
  case "$raw" in
    true|TRUE|True|yes|YES|Yes|1) echo 1 ;;
    false|FALSE|False|no|NO|No|0) echo 0 ;;
    *)
      echo "ERROR: $label expects true/false (got: '$raw')" >&2
      exit 1
      ;;
  esac
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#*=}"
      shift
      ;;
    --checks-file)
      CHECKS_FILE="$2"
      shift 2
      ;;
    --checks-file=*)
      CHECKS_FILE="${1#*=}"
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --bypass-actor-policy)
      BYPASS_ACTOR_POLICY="$2"
      shift 2
      ;;
    --bypass-actor-policy=*)
      BYPASS_ACTOR_POLICY="${1#*=}"
      shift
      ;;
    --require-conversation-resolution)
      REQUIRE_CONVERSATION_RESOLUTION=$(_normalize_bool "--require-conversation-resolution" "$2")
      shift 2
      ;;
    --require-conversation-resolution=*)
      REQUIRE_CONVERSATION_RESOLUTION=$(_normalize_bool "--require-conversation-resolution" "${1#*=}")
      shift
      ;;
    --request-copilot-review)
      REQUEST_COPILOT_REVIEW=$(_normalize_bool "--request-copilot-review" "$2")
      shift 2
      ;;
    --request-copilot-review=*)
      REQUEST_COPILOT_REVIEW=$(_normalize_bool "--request-copilot-review" "${1#*=}")
      shift
      ;;
    --dismiss-stale-approvals-on-push)
      DISMISS_STALE_APPROVALS_ON_PUSH=$(_normalize_bool "--dismiss-stale-approvals-on-push" "$2")
      shift 2
      ;;
    --dismiss-stale-approvals-on-push=*)
      DISMISS_STALE_APPROVALS_ON_PUSH=$(_normalize_bool "--dismiss-stale-approvals-on-push" "${1#*=}")
      shift
      ;;
    --required-approvals)
      REQUIRED_APPROVALS="$2"
      shift 2
      ;;
    --required-approvals=*)
      REQUIRED_APPROVALS="${1#*=}"
      shift
      ;;
    --help|-h)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ── Validate knob values ──────────────────────────────────────────────────────
case "$BYPASS_ACTOR_POLICY" in
  always|pull_request_only) ;;
  *)
    echo "ERROR: --bypass-actor-policy must be 'always' or 'pull_request_only' (got: '$BYPASS_ACTOR_POLICY')" >&2
    exit 1
    ;;
esac

if ! [[ "$REQUIRED_APPROVALS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --required-approvals must be a non-negative integer (got: '$REQUIRED_APPROVALS')" >&2
  exit 1
fi

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

# ── Admin-token guard for non-default bypass policy ──────────────────────────
# Setting bypass_actor_policy=pull_request_only is a privileged change that
# requires an admin-scoped token. We check this BEFORE the dry-run branch so
# the guard fires consistently regardless of execution mode.
if [[ "$BYPASS_ACTOR_POLICY" != "always" ]]; then
  _auth_status_output=$(gh auth status -t 2>&1 || true)
  if ! echo "$_auth_status_output" | grep -qE 'admin:org|admin:repo|repo admin'; then
    echo "ERROR: Setting bypass_actor_policy=pull_request_only requires an admin token (admin:org or repo admin scope). Re-authenticate with: gh auth refresh -s admin:org" >&2
    exit 1
  fi
fi

# ── Pre-flight: verify jq ─────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found in PATH. Install jq and retry." >&2
  exit 1
fi

# ── Resolve default branch ────────────────────────────────────────────────────
# Auto-detect from the git remote when a repo is known; fall back to "main".
# Resolved later after REPO is confirmed (see confirm-repo section).
# Override with DSO_DEFAULT_BRANCH env var for repos using a non-main default.
DEFAULT_BRANCH="${DSO_DEFAULT_BRANCH:-main}"

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

# ── Translate booleans to JSON literals ──────────────────────────────────────
if [[ "$DISMISS_STALE_APPROVALS_ON_PUSH" == "1" ]]; then
  _DISMISS_STALE_JSON="true"
else
  _DISMISS_STALE_JSON="false"
fi
if [[ "$REQUIRE_CONVERSATION_RESOLUTION" == "1" ]]; then
  _REQUIRE_CONV_JSON="true"
else
  _REQUIRE_CONV_JSON="false"
fi

# ── Build ruleset JSON payload ────────────────────────────────────────────────
# bypass_actors actor_id 5 = GitHub RepositoryRole "Admin" (standard ID on github.com)
#
# CodeQL and code-quality rules are deferred to a follow-on epic. When that
# epic ships, add rule entries here for: required_workflows (CodeQL) and the
# code-quality check contexts.
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
      "bypass_mode": "${BYPASS_ACTOR_POLICY}"
    }
  ],
  "rules": [
    {"type": "non_fast_forward"},
    {"type": "deletion"},
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": ${REQUIRED_APPROVALS},
        "dismiss_stale_reviews_on_push": ${_DISMISS_STALE_JSON},
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": ${_REQUIRE_CONV_JSON}
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

# ── Build session-branch ruleset JSON payload (F1 mitigation) ────────────────
# Second ruleset requiring review-sub-pr to pass on session/worktree branches.
#
# BRANCH-NAMING CROSS-REFERENCE (R8/R11 PR-2):
# Branch patterns are read from the source-of-truth file at
# ${CLAUDE_PLUGIN_ROOT}/config/sub-pr-branch-patterns.txt. The dispatcher
# (llm-review-dispatch-or-skip.sh) reads the SAME file to build its
# _FORCE_REVIEW regex — keeping both consumers in sync.
#
# Validation: tests/scripts/test-branch-pattern-alignment.sh asserts both
# consumers reference the file and emit consistent patterns. Drift between
# the dispatcher and the ruleset would let sub-agent branches silently
# bypass review enforcement.
SUB_PR_STATUS_JSON='[{"context": "review-sub-pr"}]'

# Resolve patterns file via BASH_SOURCE-based plugin-root derivation.
# The script lives at <plugin-root>/scripts/onboarding/provision-ruleset.sh
# and the patterns file lives at <plugin-root>/config/sub-pr-branch-patterns.txt.
# Resolving via BASH_SOURCE keeps the script and patterns file co-located
# regardless of CLAUDE_PLUGIN_ROOT env state (which may point to a different
# checkout in worktree-based development).
_PROVISION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Two levels up: scripts/onboarding → scripts → <plugin-root>. Use
# CLAUDE_PLUGIN_ROOT-honoring pattern so the no-relative-paths lint excludes
# the literal "../.." used to derive the plugin root from this script's dir.
_PR_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_PROVISION_SCRIPT_DIR/../.." 2>/dev/null && pwd || echo '')}"
_PATTERNS_FILE="${_PR_PLUGIN_ROOT}/config/sub-pr-branch-patterns.txt"
if [[ ! -f "$_PATTERNS_FILE" ]]; then
    echo "ERROR: branch-patterns source-of-truth file not found at $_PATTERNS_FILE" >&2
    exit 1
fi

# Count active (non-comment, non-blank) patterns. An empty file would produce
# an empty JSON array, which would silently disable sub-PR review enforcement
# (the ruleset's include filter would match no branches). Fail-closed instead.
# `set +e ... set -e` brackets the grep so a zero-match (grep exit 1) under
# `set -o pipefail` doesn't terminate the script before we can emit the
# diagnostic. `|| true` alone wouldn't work because pipefail propagates the
# inner exit code through the pipe.
set +e
_PATTERN_COUNT=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$_PATTERNS_FILE" 2>/dev/null | wc -l | tr -d ' ')
set -e
_PATTERN_COUNT="${_PATTERN_COUNT:-0}"
if (( _PATTERN_COUNT == 0 )); then
    echo "ERROR: branch-patterns source-of-truth file contains zero active patterns: $_PATTERNS_FILE" >&2
    echo "ERROR: refusing to provision a ruleset with empty include array — this would silently disable" >&2
    echo "ERROR: sub-PR review enforcement (empty include matches no branches)" >&2
    exit 1
fi

# Build the JSON include array from patterns file (one "refs/heads/<pattern>" per non-comment line).
SUB_PR_INCLUDE_JSON=$(
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$_PATTERNS_FILE" \
        | jq -R '"refs/heads/" + .' \
        | jq -s .
)

SUB_PR_PAYLOAD_JSON=$(cat <<EOF
{
  "name": "DSO Sub-PR Review Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ${SUB_PR_INCLUDE_JSON},
      "exclude": []
    }
  },
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "${BYPASS_ACTOR_POLICY}"
    }
  ],
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": ${SUB_PR_STATUS_JSON}
      }
    }
  ]
}
EOF
)

# ── Copilot-review annotation ────────────────────────────────────────────────
# GitHub does not currently expose a Ruleset rule for "request Copilot review";
# Copilot review is a repo-level (or PR-time UI) setting. When the user opts in,
# emit a clearly-labelled annotation so the choice is recorded in the dry-run
# output and the success summary. When the API exposes the field, this annotation
# will be replaced by an actual gh-api call.
_COPILOT_ANNOTATION=""
if [[ "$REQUEST_COPILOT_REVIEW" == "1" ]]; then
  _COPILOT_ANNOTATION="request_copilot_review=true (recorded; GitHub does not currently expose this via Rulesets — automation will be added when API support lands)"
fi

# ── Dry-run mode ──────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  echo "=== DSO_DRY_RUN=1: No API calls will be made ==="
  echo ""
  echo "--- Main branch ruleset JSON payload ---"
  echo "$PAYLOAD_JSON"
  echo ""
  echo "--- Session-branch ruleset JSON payload (F1) ---"
  echo "$SUB_PR_PAYLOAD_JSON"
  echo ""
  if [[ -n "$_COPILOT_ANNOTATION" ]]; then
    echo "--- Copilot review annotation ---"
    echo "$_COPILOT_ANNOTATION"
    echo ""
  fi
  if [[ -n "$REPO" ]]; then
    echo "--- gh api invocations (not executed) ---"
    echo "gh api --method POST /repos/${REPO}/rulesets --input <(echo '\$main_payload')"
    echo "gh api --method POST /repos/${REPO}/rulesets --input <(echo '\$sub_pr_payload')"
    echo ""
    echo "--- gh repo edit invocation (not executed) ---"
    echo "gh repo edit ${REPO} --enable-auto-merge"
  else
    echo "--- gh api invocations (not executed) ---"
    echo "gh api --method POST /repos/{owner}/{repo}/rulesets --input <(echo '\$main_payload')"
    echo "gh api --method POST /repos/{owner}/{repo}/rulesets --input <(echo '\$sub_pr_payload')"
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
  echo "About to provision two rulesets on repo: $REPO"
  echo "  1. 'DSO CI Enforcement' — target: $DEFAULT_BRANCH"
  echo "  2. 'DSO Sub-PR Review Enforcement' — target: session/worktree branches"
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

# ── Create session-branch ruleset (F1 mitigation) ────────────────────────────
SUB_PR_TMPFILE=$(mktemp /tmp/provision-sub-pr-ruleset-payload.XXXXXX)
trap 'rm -f "$TMPFILE" "$SUB_PR_TMPFILE"' EXIT

echo "$SUB_PR_PAYLOAD_JSON" > "$SUB_PR_TMPFILE"

echo "Creating session-branch ruleset on $REPO ..."
SUB_PR_RESPONSE=$(gh api --method POST "/repos/${REPO}/rulesets" --input "$SUB_PR_TMPFILE")
SUB_PR_RULESET_ID=$(echo "$SUB_PR_RESPONSE" | jq -r '.id')

# ── Enable auto-merge ─────────────────────────────────────────────────────────
echo "Enabling auto-merge on $REPO ..."
gh repo edit "$REPO" --enable-auto-merge

# ── Success summary ───────────────────────────────────────────────────────────
echo ""
echo "=== DSO CI Enforcement Rulesets Provisioned ==="
echo "Repository:          $REPO"
echo "Main branch:         $DEFAULT_BRANCH"
echo "Main ruleset ID:     ${RULESET_ID:-unknown}"
echo "Sub-PR ruleset ID:   ${SUB_PR_RULESET_ID:-unknown}"
echo "Auto-merge:          enabled"
if [[ -n "$_COPILOT_ANNOTATION" ]]; then
  echo "Note:                $_COPILOT_ANNOTATION"
fi
