#!/usr/bin/env bash
# commit-emit-skip-markers.sh
# Emits .skipped compliance-verifier markers for all five required commit steps.
# Called when the commit workflow skips review (e.g. SKIP_REVIEW=true, enforcement.strategy=ci).
#
# Usage: bash commit-emit-skip-markers.sh <reason>
#
# Arguments:
#   reason  — human-readable string recorded in each .skipped file and breadcrumb log
#
# Environment:
#   CLAUDE_PLUGIN_ROOT — path to the dso plugin root (required)
#   REPO_ROOT          — repo root; defaults to git rev-parse --show-toplevel

set -euo pipefail

_reason="${1:-skip-review}"

_REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
_DSO="${_REPO_ROOT}/.claude/scripts/dso"

# Resolve ARTIFACTS_DIR via the shared helper in deps.sh.
# shellcheck source=../hooks/lib/deps.sh
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

"$_DSO" commit-step skip test               "$_reason"
"$_DSO" commit-step skip format             "$_reason"
"$_DSO" commit-step skip lint               "$_reason"
"$_DSO" commit-step skip classifier-dispatch "$_reason"
"$_DSO" commit-step skip reviewer-record    "$_reason"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-2-skip-review-skipped-markers" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
