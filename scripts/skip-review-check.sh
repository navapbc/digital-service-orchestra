#!/usr/bin/env bash
set -uo pipefail
# lockpick-workflow/scripts/skip-review-check.sh
# Classifies a list of changed files to determine if review can be skipped.
#
# Reads file list from stdin (one file per line).
# Exits 0  if SKIP_REVIEW=true  (all files are non-reviewable — review can be skipped).
# Exits 1  if SKIP_REVIEW=false (at least one reviewable file found — full review required).
#
# Usage:
#   git diff HEAD --name-only | bash lockpick-workflow/scripts/skip-review-check.sh
#   echo '.tickets/abc.md' | bash scripts/skip-review-check.sh
#
# Classification logic extracted from COMMIT-WORKFLOW.md Step 0.5 (lines 48-74).

set -uo pipefail

# Source config-paths.sh for portable path resolution
_SKIP_REVIEW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_PATHS="${CLAUDE_PLUGIN_ROOT:-$_SKIP_REVIEW_DIR/..}/hooks/lib/config-paths.sh"
if [ -f "$_CONFIG_PATHS" ]; then
    # shellcheck source=../hooks/lib/config-paths.sh
    source "$_CONFIG_PATHS"
fi

# Build config-driven snapshot patterns (defaults ensure non-empty values)
_CFG_APP="${CFG_APP_DIR:-app}"
_CFG_TEST="${CFG_TEST_DIR:-tests}"
# Guard: ensure app dir is non-empty to prevent wildcard degradation in case patterns
[[ -z "$_CFG_APP" ]] && _CFG_APP="app"
[[ -z "$_CFG_TEST" ]] && _CFG_TEST="tests"
_E2E_SNAP_PREFIX="${_CFG_APP}/${_CFG_TEST}/e2e/snapshots/"
_UNIT_SNAP_PREFIX="${_CFG_APP}/${_CFG_TEST}/unit/templates/snapshots/"

SKIP_REVIEW=true
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    # Agent guidance always requires review (checked first, overrides docs/* below)
    case "$file" in
        .claude/hooks/*|.claude/hookify.*) SKIP_REVIEW=false; break ;;
        lockpick-workflow/skills/*|lockpick-workflow/hooks/*|lockpick-workflow/docs/workflows/*) SKIP_REVIEW=false; break ;;
        CLAUDE.md) SKIP_REVIEW=false; break ;;
    esac
    # .checkpoint-needs-review always requires a full review (see COMMIT-WORKFLOW.md Note)
    case "$file" in
        .checkpoint-needs-review) SKIP_REVIEW=false; break ;;
    esac
    # Non-reviewable files
    case "$file" in
        .tickets/*) ;;                                                              # ticket metadata
        .sync-state.json) ;;                                                       # sync state metadata
        ${_E2E_SNAP_PREFIX}*|${_UNIT_SNAP_PREFIX}*.html) ;;                       # visual snapshots
        *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.webp) ;;                            # images
        *.pdf|*.docx) ;;                                                           # binary docs
        .claude/session-logs/*|.claude/docs/*|docs/*) ;;                          # logs and non-agent docs
        *) SKIP_REVIEW=false; break ;;
    esac
done

if [[ "$SKIP_REVIEW" == "true" ]]; then
    exit 0
else
    exit 1
fi
