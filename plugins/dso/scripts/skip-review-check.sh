#!/usr/bin/env bash
set -uo pipefail
# scripts/skip-review-check.sh
# Classifies a list of changed files to determine if review can be skipped.
#
# Reads file list from stdin (one file per line).
# Exits 0  if SKIP_REVIEW=true  (all files are non-reviewable — review can be skipped).
# Exits 1  if SKIP_REVIEW=false (at least one reviewable file found — full review required).
#
# Usage:
#   git diff HEAD --name-only | bash scripts/skip-review-check.sh
#   echo '.tickets-tracker/abc.md' | bash scripts/skip-review-check.sh
#
# Classification logic extracted from COMMIT-WORKFLOW.md Step 0.5 (lines 48-74).

set -uo pipefail

# Source config-paths.sh for portable path resolution.
# Resolve _PLUGIN_ROOT from BASH_SOURCE so the script works without a pre-set
# CLAUDE_PLUGIN_ROOT (which is exported by .claude/scripts/dso, but absent
# under direct invocation — e.g., test isolation under `set -u`).
_SKIP_REVIEW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_SKIP_REVIEW_DIR/.." && pwd)}"
_CONFIG_PATHS="${_PLUGIN_ROOT}/hooks/lib/config-paths.sh"
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

# ── Load non-reviewable patterns from shared allowlist ──────────────────────
# _PLUGIN_ROOT is already resolved above (with BASH_SOURCE fallback when
# CLAUDE_PLUGIN_ROOT is unset). Reuse it instead of dereferencing
# ${CLAUDE_PLUGIN_ROOT} again under `set -u`.
_ALLOWLIST_FILE="${ALLOWLIST_OVERRIDE:-$_PLUGIN_ROOT/hooks/lib/review-gate-allowlist.conf}"
_ALLOWLIST_PATTERNS=()
_ALLOWLIST_LOADED=false

if [[ -f "$_ALLOWLIST_FILE" ]]; then
    _ALLOWLIST_LOADED=true
    while IFS= read -r _line; do
        # Skip empty lines and comments
        [[ -z "$_line" || "$_line" == \#* ]] && continue
        # Convert glob patterns: ** → * for bash pattern matching
        # e.g., .tickets-tracker/** → .tickets-tracker/*
        _pat="${_line/\*\*/*}"
        _ALLOWLIST_PATTERNS+=("$_pat")
    done < "$_ALLOWLIST_FILE"
else
    # Graceful degradation: fall back to hardcoded patterns when allowlist is missing
    _ALLOWLIST_PATTERNS=(
        ".tickets-tracker/*"
        ".sync-state.json"
        ".checkpoint-needs-review"
        "*.png" "*.jpg" "*.jpeg" "*.gif" "*.svg" "*.ico" "*.webp"
        "*.pdf" "*.docx"
        ".claude/session-logs/*" ".claude/docs/*" "docs/*"
    )
fi

# Add config-driven snapshot patterns dynamically (not in allowlist)
_ALLOWLIST_PATTERNS+=("${_E2E_SNAP_PREFIX}*")
_ALLOWLIST_PATTERNS+=("${_UNIT_SNAP_PREFIX}*.html")

# _matches_allowlist: check if a file matches any non-reviewable pattern
_matches_allowlist() {
    local f="$1"
    for _pat in "${_ALLOWLIST_PATTERNS[@]}"; do
        # shellcheck disable=SC2254
        case "$f" in $_pat) return 0 ;; esac
    done
    return 1
}

SKIP_REVIEW=true
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    # Agent guidance always requires review (checked first, overrides allowlist)
    case "$file" in
        .claude/hooks/*|.claude/hookify.*) SKIP_REVIEW=false; break ;;
        .claude/skills/*) SKIP_REVIEW=false; break ;;
        hooks/*|skills/*|docs/workflows/*) SKIP_REVIEW=false; break ;;
        CLAUDE.md) SKIP_REVIEW=false; break ;;
    esac
    # .checkpoint-needs-review always requires a full review (see COMMIT-WORKFLOW.md Note)
    case "$file" in
        .checkpoint-needs-review) SKIP_REVIEW=false; break ;;
    esac
    # Non-reviewable files — driven by shared review-gate-allowlist.conf
    if ! _matches_allowlist "$file"; then
        SKIP_REVIEW=false; break
    fi
done

if [[ "$SKIP_REVIEW" == "true" ]]; then
    exit 0
else
    exit 1
fi
