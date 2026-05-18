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

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not found in PATH." >&2
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
# All three conditions are evaluated by a single python3 invocation
# (jq-free; PR #140 retro-review). The script emits one of:
#   OK                — all conditions pass
#   NO_SESSION_PATTERN — condition 1 failed
#   MISSING_CHECK      — condition 2 failed
#   HAS_LINEAR         — condition 3 failed
_PRELIGHT_RESULT="$(DSO_CHECK_NAME="$CHECK_NAME" python3 - "$TMPFILE" <<'PYEOF'
import json, os, sys

with open(sys.argv[1]) as f:
    try:
        data = json.load(f)
    except Exception:
        print("NO_SESSION_PATTERN"); sys.exit(0)

# data may be {"rulesets": [...]} or a bare array
rulesets = data.get("rulesets") if isinstance(data, dict) and "rulesets" in data else data
if not isinstance(rulesets, list):
    print("NO_SESSION_PATTERN"); sys.exit(0)

def _matches_session(pattern: str) -> bool:
    if not isinstance(pattern, str):
        return False
    fixed = {"refs/heads/session-*", "session-*", "refs/heads/session/*", "session/*"}
    if pattern in fixed:
        return True
    return pattern.startswith("refs/heads/session") or pattern.startswith("session")

# Condition 1: find the first ruleset whose ref_name.include contains a session pattern
matching = None
for rs in rulesets:
    if not isinstance(rs, dict):
        continue
    includes = (rs.get("conditions") or {}).get("ref_name", {}).get("include") or []
    if any(_matches_session(p) for p in includes):
        matching = rs
        break

if matching is None:
    print("NO_SESSION_PATTERN"); sys.exit(0)

rules = matching.get("rules") or []
check_name = os.environ.get("DSO_CHECK_NAME", "")

# Condition 2: required_status_checks rule with the configured check_name context
required_checks = []
for r in rules:
    if isinstance(r, dict) and r.get("type") == "required_status_checks":
        params = r.get("parameters") or {}
        required_checks.extend(params.get("required_status_checks") or [])
contexts = [c.get("context") for c in required_checks if isinstance(c, dict)]
if check_name not in contexts:
    print("MISSING_CHECK"); sys.exit(0)

# Condition 3: no linear_history rule
if any(isinstance(r, dict) and r.get("type") == "linear_history" for r in rules):
    print("HAS_LINEAR"); sys.exit(0)

print("OK")
PYEOF
)"

case "$_PRELIGHT_RESULT" in
    OK)
        echo "GitHub Ruleset preflight check: success"
        echo "  - session-* branch pattern: found"
        echo "  - Required status check '$CHECK_NAME': found"
        echo "  - No linear_history constraint: confirmed"
        exit 0
        ;;
    NO_SESSION_PATTERN)
        echo "ERROR: No GitHub Ruleset found with a session-* branch pattern." >&2
        echo "  Expected: a Ruleset with conditions.ref_name.include containing 'refs/heads/session-*' or 'session-*'." >&2
        echo "  See: INSTALL.md#github-rulesets-for-session-branches" >&2
        exit 1
        ;;
    MISSING_CHECK)
        echo "ERROR: Required status check '$CHECK_NAME' not found in the session-* Ruleset." >&2
        echo "  The Ruleset must have a 'required_status_checks' rule with context '$CHECK_NAME'." >&2
        echo "  See: INSTALL.md#github-rulesets-for-session-branches" >&2
        exit 1
        ;;
    HAS_LINEAR)
        echo "ERROR: The session-* Ruleset contains a 'required_linear_history' rule." >&2
        echo "  This would block the sprint merge strategy (which uses merge commits)." >&2
        echo "  Remove the 'required_linear_history' rule from the session-* Ruleset." >&2
        echo "  See: INSTALL.md#github-rulesets-for-session-branches" >&2
        exit 1
        ;;
    *)
        echo "ERROR: preflight check returned unexpected result: ${_PRELIGHT_RESULT}" >&2
        exit 1
        ;;
esac
