#!/usr/bin/env bash
# mirror-defenses-to-pr.sh
# Standalone script: reads defense records from stdin and posts them to a PR.
# Usage: <some-command> | bash mirror-defenses-to-pr.sh <pr_number> [repo]
#
# Arguments:
#   pr_number  — GitHub PR number to post comments on (default: $PR_NUMBER env var)
#   repo       — owner/repo slug (default: $REPO_SLUG env var)
#
# Environment:
#   PR_NUMBER       — fallback PR number when positional arg is absent
#   REPO_SLUG       — fallback repo slug when positional arg is absent
#   GITHUB_FORK_PR  — set to 1 to enable fork-PR no-op mode
#   GH_CMD          — gh binary override for tests (default: gh)

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./review-github-defense-store.sh
source "$_SCRIPT_DIR/review-github-defense-store.sh"

_pr_number="${1:-${PR_NUMBER:-}}"
_repo="${2:-${REPO_SLUG:-}}"

review_mirror_defenses_to_pr "$_pr_number" "$_repo"
