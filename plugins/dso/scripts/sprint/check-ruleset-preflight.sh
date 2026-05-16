#!/usr/bin/env bash
set -euo pipefail
# check-ruleset-preflight.sh
# Validates GitHub Rulesets are correctly configured for session-* branches.
#
# Usage:
#   check-ruleset-preflight.sh [--repo <owner/repo>] [--config <path-to-dso-config.conf>]
#
# Environment:
#   DSO_CONFIG_FILE — path to dso-config.conf (overrides default discovery)
#
# Exit codes:
#   0 = all 3 Ruleset conditions satisfied
#   1 = validation failure or dependency missing
#
# Validation conditions (all 3 must pass):
#   1. A Ruleset exists with conditions.ref_name.include containing session-* pattern
#   2. required_status_checks rule exists with check_name in required_status_checks array
#   3. linear_history rule does NOT appear in the matching ruleset
#
# Reads dso.review.check_name from dso-config.conf; falls back to 'Sprint Story Review'.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Dependency checks ─────────────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI is required but not found in PATH." >&2
    echo "  Install: https://cli.github.com/" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found in PATH." >&2
    echo "  Install: https://stedolan.github.io/jq/" >&2
    exit 1
fi

# ── Argument parsing ──────────────────────────────────────────────────────────
REPO_ARG=""
CONFIG_FILE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO_ARG="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE_ARG="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: check-ruleset-preflight.sh [--repo <owner/repo>] [--config <path>]" >&2
            exit 1
            ;;
    esac
done

# ── Resolve dso-config.conf path ──────────────────────────────────────────────
# Priority: DSO_CONFIG_FILE env var > --config arg > default discovery
_resolve_config_file() {
    if [[ -n "${DSO_CONFIG_FILE:-}" ]]; then
        echo "$DSO_CONFIG_FILE"
        return
    fi
    if [[ -n "$CONFIG_FILE_ARG" ]]; then
        echo "$CONFIG_FILE_ARG"
        return
    fi
    # Default: look for .claude/dso-config.conf relative to repo root (walk up from script)
    local dir="$SCRIPT_DIR"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.claude/dso-config.conf" ]]; then
            echo "$dir/.claude/dso-config.conf"
            return
        fi
        dir="$(dirname "$dir")"
    done
    echo ""
}

# ── Read check_name from config ───────────────────────────────────────────────
_read_check_name() {
    local config_file="$1"
    local default_name="Sprint Story Review"

    if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
        echo "$default_name"
        return
    fi

    local value
    value="$(grep -E '^dso\.review\.check_name=' "$config_file" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default_name"
    fi
}

CONFIG_FILE="$(_resolve_config_file)"
CHECK_NAME="$(_read_check_name "$CONFIG_FILE")"

# ── Fetch rulesets ────────────────────────────────────────────────────────────
_fetch_rulesets() {
    local api_path
    if [[ -n "$REPO_ARG" ]]; then
        api_path="/repos/$REPO_ARG/rulesets"
    else
        api_path="$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null | xargs -I{} echo "/repos/{}/rulesets")" || true
        if [[ -z "$api_path" ]]; then
            api_path="/repos/rulesets"
        fi
    fi
    gh api "$api_path" 2>&1
}

TMPFILE="$(mktemp /tmp/check-ruleset-preflight.XXXXXX)"
trap 'rm -f "$TMPFILE"' EXIT

if ! _fetch_rulesets > "$TMPFILE" 2>&1; then
    echo "ERROR: Failed to fetch rulesets from GitHub API." >&2
    cat "$TMPFILE" >&2
    exit 1
fi

RULESETS_JSON="$(cat "$TMPFILE")"

# ── Validation ────────────────────────────────────────────────────────────────
# Condition 1: Find a ruleset with a session-* branch pattern
# Accept patterns like: refs/heads/session-*, session-*, refs/heads/session/*
SESSION_RULESET_IDX="$(echo "$RULESETS_JSON" | jq '
    .rulesets // . |
    to_entries[] |
    select(
        .value.conditions?.ref_name?.include? // [] |
        any(. == "refs/heads/session-*" or . == "session-*" or . == "refs/heads/session/*" or . == "session/*" or startswith("refs/heads/session") or startswith("session"))
    ) |
    .key
' 2>/dev/null | head -1)" || SESSION_RULESET_IDX=""

if [[ -z "$SESSION_RULESET_IDX" ]]; then
    echo "ERROR: No GitHub Ruleset found with a session-* branch pattern." >&2
    echo "  Expected: a Ruleset with conditions.ref_name.include containing 'refs/heads/session-*' or 'session-*'." >&2
    echo "  See: INSTALL.md#github-rulesets-for-session-branches" >&2
    exit 1
fi

# Extract the matching ruleset for further validation
MATCHING_RULESET="$(echo "$RULESETS_JSON" | jq "(.rulesets // .)[$SESSION_RULESET_IDX]")"

# Condition 2: Sprint Story Review (or configured check_name) is in required_status_checks
HAS_CHECK="$(echo "$MATCHING_RULESET" | jq --arg check_name "$CHECK_NAME" '
    .rules // [] |
    map(select(.type == "required_status_checks")) |
    length > 0 and
    (
        map(.parameters.required_status_checks // []) |
        flatten |
        map(.context) |
        any(. == $check_name)
    )
' 2>/dev/null)" || HAS_CHECK="false"

if [[ "$HAS_CHECK" != "true" ]]; then
    echo "ERROR: Required status check '$CHECK_NAME' (Sprint Story Review) not found in the session-* Ruleset." >&2
    echo "  The Ruleset must have a 'required_status_checks' rule with context '$CHECK_NAME'." >&2
    echo "  See: INSTALL.md#github-rulesets-for-session-branches" >&2
    exit 1
fi

# Condition 3: No linear_history rule (would block sprint merge)
HAS_LINEAR="$(echo "$MATCHING_RULESET" | jq '
    .rules // [] |
    map(select(.type == "linear_history")) |
    length > 0
' 2>/dev/null)" || HAS_LINEAR="false"

if [[ "$HAS_LINEAR" == "true" ]]; then
    echo "ERROR: The session-* Ruleset contains a 'required_linear_history' rule." >&2
    echo "  This would block the sprint merge strategy (which uses merge commits)." >&2
    echo "  Remove the 'required_linear_history' rule from the session-* Ruleset." >&2
    echo "  See: INSTALL.md#github-rulesets-for-session-branches" >&2
    exit 1
fi

# ── All conditions pass ───────────────────────────────────────────────────────
echo "GitHub Ruleset preflight check: success"
echo "  - session-* branch pattern: found"
echo "  - Required status check '$CHECK_NAME': found"
echo "  - No linear_history constraint: confirmed"
exit 0
