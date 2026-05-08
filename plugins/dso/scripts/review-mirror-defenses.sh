#!/usr/bin/env bash
# review-mirror-defenses.sh
# Standalone script: reads defense records from stdin and mirrors them to a
# GitHub PR as comments via `gh pr comment`.
#
# Usage:
#   <some-command> | bash review-mirror-defenses.sh
#
# Environment:
#   PR_NUMBER       — PR number to post comments on (default: empty string)
#   REPO_SLUG       — owner/repo string (default: empty string)
#   GITHUB_FORK_PR  — set to 1 to enable fork-PR no-op mode
#   GH_CMD          — gh binary override for tests (default: gh)

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./review-github-defense-store.sh
source "$_SCRIPT_DIR/review-github-defense-store.sh"

_pr_number="${PR_NUMBER:-}"
_repo="${REPO_SLUG:-}"

review_mirror_defenses_to_pr "$_pr_number" "$_repo"
