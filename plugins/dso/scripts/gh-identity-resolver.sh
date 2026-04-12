#!/usr/bin/env bash
# gh-identity-resolver.sh
# Resolves GitHub identity fields for bridge configuration.
#
# Modes:
#   --own-identity   Derive BRIDGE_BOT_LOGIN, BRIDGE_BOT_NAME, BRIDGE_BOT_EMAIL
#                    from the authenticated gh user.
#   --bot            Output placeholder values for bot account configuration.
#   --env-id         Resolve BRIDGE_ENV_ID from repo context.
#
# Output: key=value lines on stdout. Diagnostics on stderr.
# Exit codes: 0=success, 1=fatal error, 2=PROMPT_NEEDED (email unresolvable)

set -uo pipefail

_log() { printf '%s\n' "$*" >&2; }

# ── Precondition: gh CLI available and authenticated ─────────────────────────
_require_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        _log "ERROR: gh CLI not found. Install from https://cli.github.com/"
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        _log "ERROR: gh is not authenticated. Run 'gh auth login' first."
        exit 1
    fi
}

# ── Resolve email with 3-tier fallback ───────────────────────────────────────
# 1. gh api user .email field
# 2. gh api user/emails (primary + verified)
# 3. PROMPT_NEEDED signal
_resolve_email() {
    local profile_json="$1"

    # Tier 1: email from user profile
    local email
    email=$(printf '%s' "$profile_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
e = d.get('email')
if e and e != 'null':
    print(e)
" 2>/dev/null)

    if [[ -n "$email" ]]; then
        echo "$email"
        return 0
    fi

    # Tier 2: user/emails API (primary + verified)
    _log "Profile email is null; trying user/emails API..."
    local emails_json
    local emails_rc=0
    emails_json=$(gh api user/emails 2>/dev/null) || emails_rc=$?

    if [[ $emails_rc -ne 0 ]]; then
        # 404 means the scope is missing
        _log "user/emails API failed (scope may be missing); falling back to PROMPT_NEEDED"
        echo "PROMPT_NEEDED"
        return 0
    fi

    # Check for empty array
    local primary_email
    primary_email=$(printf '%s' "$emails_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    sys.exit(1)
for entry in data:
    if entry.get('primary') and entry.get('verified'):
        print(entry['email'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null)

    if [[ -n "$primary_email" ]]; then
        echo "$primary_email"
        return 0
    fi

    # Tier 3: PROMPT_NEEDED
    _log "No primary verified email found; signalling PROMPT_NEEDED"
    echo "PROMPT_NEEDED"
    return 0
}

# ── Resolve BRIDGE_ENV_ID ────────────────────────────────────────────────────
_resolve_env_id() {
    # Try gh repo view first
    local repo_slug
    repo_slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || true

    if [[ -n "$repo_slug" && "$repo_slug" == */* ]]; then
        local org repo
        org="${repo_slug%%/*}"
        repo="${repo_slug##*/}"
        echo "github-${org}-${repo}"
        return 0
    fi

    # Fallback: parse git remote -v
    _log "gh repo view failed; falling back to git remote -v"
    local remote_line
    remote_line=$(git remote -v 2>/dev/null | head -1) || true

    if [[ -z "$remote_line" ]]; then
        _log "ERROR: No git remote found"
        return 1
    fi

    # Parse both SSH (git@github.com:org/repo.git) and HTTPS (https://github.com/org/repo.git)
    local parsed
    parsed=$(printf '%s' "$remote_line" | python3 -c "
import sys, re
line = sys.stdin.read().strip()
# SSH: git@github.com:org/repo.git
m = re.search(r'github\.com[:/]([^/]+)/([^/\s]+?)(?:\.git)?(?:\s|$)', line)
if m:
    print(f'github-{m.group(1)}-{m.group(2)}')
    sys.exit(0)
sys.exit(1)
" 2>/dev/null)

    if [[ -n "$parsed" ]]; then
        echo "$parsed"
        return 0
    fi

    _log "ERROR: Could not parse GitHub org/repo from remote"
    return 1
}

# ── Mode: --own-identity ─────────────────────────────────────────────────────
_mode_own_identity() {
    _require_gh

    _log "Fetching GitHub user profile..."
    local user_json
    user_json=$(gh api user 2>/dev/null) || {
        _log "ERROR: gh api user failed"
        exit 1
    }

    local login name
    login=$(printf '%s' "$user_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['login'])" 2>/dev/null)
    name=$(printf '%s' "$user_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)

    if [[ -z "$login" ]]; then
        _log "ERROR: Could not extract login from gh api user"
        exit 1
    fi

    echo "BRIDGE_BOT_LOGIN=$login"
    echo "BRIDGE_BOT_NAME=$name"

    local email_result
    email_result=$(_resolve_email "$user_json")

    if [[ "$email_result" == "PROMPT_NEEDED" ]]; then
        echo "BRIDGE_BOT_EMAIL=PROMPT_NEEDED"
        exit 0
    fi

    echo "BRIDGE_BOT_EMAIL=$email_result"
    exit 0
}

# ── Mode: --bot ──────────────────────────────────────────────────────────────
_mode_bot() {
    echo "BRIDGE_BOT_LOGIN=github-actions[bot]"
    echo "BRIDGE_BOT_NAME=GitHub Actions"
    echo "BRIDGE_BOT_EMAIL=41898282+github-actions[bot]@users.noreply.github.com"
    exit 0
}

# ── Mode: --env-id ───────────────────────────────────────────────────────────
_mode_env_id() {
    _require_gh

    local env_id
    env_id=$(_resolve_env_id) || {
        _log "ERROR: Could not resolve environment ID"
        exit 1
    }

    echo "BRIDGE_ENV_ID=$env_id"
    exit 0
}

# ── Main ─────────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    _log "Usage: gh-identity-resolver.sh [--own-identity|--bot|--env-id]"
    exit 1
fi

case "$1" in
    --own-identity) _mode_own_identity ;;
    --bot)          _mode_bot ;;
    --env-id)       _mode_env_id ;;
    *)
        _log "ERROR: Unknown mode: $1"
        _log "Usage: gh-identity-resolver.sh [--own-identity|--bot|--env-id]"
        exit 1
        ;;
esac
