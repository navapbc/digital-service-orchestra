#!/usr/bin/env bash
# commit-emit-skip-markers.sh
# Emits .skipped compliance-verifier markers for all five required commit steps.
# Called when the commit workflow skips review (e.g. SKIP_REVIEW=true, dso.workflow=ci-pr).
#
# Usage: bash commit-emit-skip-markers.sh <reason> [<breadcrumb-label>]
#
# Arguments:
#   reason           — human-readable string recorded in each .skipped file and breadcrumb log
#   breadcrumb-label — breadcrumb tag written to commit-breadcrumbs.log
#                      (default: step-2-skip-review-skipped-markers)
#
# Environment:
#   CLAUDE_PLUGIN_ROOT — path to the dso plugin root (required)
#   REPO_ROOT          — repo root; defaults to git rev-parse --show-toplevel

set -euo pipefail

if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    echo "ERROR: CLAUDE_PLUGIN_ROOT is not set. Set it to the dso plugin root directory." >&2
    exit 1
fi

_reason="${1:-skip-review}"
_breadcrumb_label="${2:-step-2-skip-review-skipped-markers}"

_REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
_DSO="${_REPO_ROOT}/.claude/scripts/dso"

# Resolve ARTIFACTS_DIR via the shared helper in deps.sh.
# shellcheck source=../hooks/lib/deps.sh
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

"$_DSO" commit-step skip test               "$_reason" || { echo "ERROR: failed to emit skip marker for 'test'" >&2; exit 1; }
"$_DSO" commit-step skip format             "$_reason" || { echo "ERROR: failed to emit skip marker for 'format'" >&2; exit 1; }
"$_DSO" commit-step skip lint               "$_reason" || { echo "ERROR: failed to emit skip marker for 'lint'" >&2; exit 1; }
"$_DSO" commit-step skip classifier-dispatch "$_reason" || { echo "ERROR: failed to emit skip marker for 'classifier-dispatch'" >&2; exit 1; }
"$_DSO" commit-step skip reviewer-record    "$_reason" || { echo "ERROR: failed to emit skip marker for 'reviewer-record'" >&2; exit 1; }

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${_breadcrumb_label}" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
