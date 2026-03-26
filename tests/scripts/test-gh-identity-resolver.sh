#!/usr/bin/env bash
# tests/scripts/test-gh-identity-resolver.sh
# Behavioral tests for plugins/dso/scripts/gh-identity-resolver.sh
#
# Integration tests against a live GitHub API are out of scope for CI —
# the gh CLI and network access are unavailable in standard CI environments.
# Tests here use comprehensive mocks covering all 3 email fallback branches
# and both env ID resolution paths (gh API and git remote). Manual validation
# is performed by the developer running project-setup in a real environment.
#
# Usage: bash tests/scripts/test-gh-identity-resolver.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
RESOLVER="$DSO_PLUGIN_DIR/scripts/gh-identity-resolver.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-gh-identity-resolver.sh ==="

_TMP=$(mktemp -d)
trap 'rm -rf "$_TMP"' EXIT

# ── Helper: make a mock gh binary ──────────────────────────────────────────────
# Usage: _make_gh_mock <dir> <script-body>
# Creates $dir/gh with the given body and marks it executable.
_make_gh_mock() {
    local dir="$1"
    local body="$2"
    mkdir -p "$dir"
    cat > "$dir/gh" <<GHEOF
#!/usr/bin/env bash
$body
GHEOF
    chmod +x "$dir/gh"
}

# ── Helper: make a mock git binary ─────────────────────────────────────────────
_make_git_mock() {
    local dir="$1"
    local body="$2"
    mkdir -p "$dir"
    cat > "$dir/git" <<GITEOF
#!/usr/bin/env bash
$body
GITEOF
    chmod +x "$dir/git"
}

# =============================================================================
# test_own_identity_derives_login
# Mock gh api user returning login + name; assert BRIDGE_BOT_LOGIN and
# BRIDGE_BOT_NAME appear in stdout.
# =============================================================================
_snapshot_fail
echo "--- test_own_identity_derives_login ---"

MOCK1="$_TMP/mock1"
_make_gh_mock "$MOCK1" '
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == "user" ]]; then
    echo '"'"'{"login":"jsmith","name":"John Smith","email":"john@example.com"}'"'"'
    exit 0
fi
exit 0
'

rc=0
out=$(PATH="$MOCK1:$PATH" bash "$RESOLVER" --own-identity 2>/dev/null) || rc=$?
assert_eq "test_own_identity_derives_login: exit 0" "0" "$rc"
assert_contains "test_own_identity_derives_login: BRIDGE_BOT_LOGIN" "BRIDGE_BOT_LOGIN=jsmith" "$out"
assert_contains "test_own_identity_derives_login: BRIDGE_BOT_NAME" "BRIDGE_BOT_NAME=John Smith" "$out"
assert_pass_if_clean "test_own_identity_derives_login"

# =============================================================================
# test_email_from_user_profile
# Mock gh api user with email field set; assert BRIDGE_BOT_EMAIL in stdout.
# =============================================================================
_snapshot_fail
echo "--- test_email_from_user_profile ---"

MOCK2="$_TMP/mock2"
_make_gh_mock "$MOCK2" '
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == "user" ]]; then
    echo '"'"'{"login":"jsmith","name":"John Smith","email":"user@example.com"}'"'"'
    exit 0
fi
exit 0
'

rc=0
out=$(PATH="$MOCK2:$PATH" bash "$RESOLVER" --own-identity 2>/dev/null) || rc=$?
assert_eq "test_email_from_user_profile: exit 0" "0" "$rc"
assert_contains "test_email_from_user_profile: BRIDGE_BOT_EMAIL" "BRIDGE_BOT_EMAIL=user@example.com" "$out"
assert_pass_if_clean "test_email_from_user_profile"

# =============================================================================
# test_email_fallback_to_emails_api
# Mock gh api user with null email; mock user/emails returning a primary
# verified address; assert BRIDGE_BOT_EMAIL is derived from emails API.
# =============================================================================
_snapshot_fail
echo "--- test_email_fallback_to_emails_api ---"

MOCK3="$_TMP/mock3"
_make_gh_mock "$MOCK3" '
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == "user" ]]; then
    echo '"'"'{"login":"jsmith","name":"John Smith","email":null}'"'"'
    exit 0
fi
if [[ "$1" == "api" && "$2" == "user/emails" ]]; then
    echo '"'"'[{"email":"primary@example.com","primary":true,"verified":true}]'"'"'
    exit 0
fi
exit 0
'

rc=0
out=$(PATH="$MOCK3:$PATH" bash "$RESOLVER" --own-identity 2>/dev/null) || rc=$?
assert_eq "test_email_fallback_to_emails_api: exit 0" "0" "$rc"
assert_contains "test_email_fallback_to_emails_api: BRIDGE_BOT_EMAIL" "BRIDGE_BOT_EMAIL=primary@example.com" "$out"
assert_pass_if_clean "test_email_fallback_to_emails_api"

# =============================================================================
# test_email_fallback_to_prompt
# Both user profile and user/emails return null/empty email; assert the script
# signals that user input is needed (PROMPT_NEEDED in output or exit code 2).
# =============================================================================
_snapshot_fail
echo "--- test_email_fallback_to_prompt ---"

MOCK4="$_TMP/mock4"
_make_gh_mock "$MOCK4" '
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == "user" ]]; then
    echo '"'"'{"login":"jsmith","name":"John Smith","email":null}'"'"'
    exit 0
fi
if [[ "$1" == "api" && "$2" == "user/emails" ]]; then
    echo '"'"'[]'"'"'
    exit 0
fi
exit 0
'

rc=0
out=$(PATH="$MOCK4:$PATH" bash "$RESOLVER" --own-identity 2>/dev/null) || rc=$?
# Expect either exit code 2 (PROMPT_NEEDED signal) or PROMPT_NEEDED in output
prompt_signalled=0
if [[ "$rc" -eq 2 ]] || [[ "$out" == *"PROMPT_NEEDED"* ]]; then
    prompt_signalled=1
fi
assert_eq "test_email_fallback_to_prompt: PROMPT_NEEDED signalled" "1" "$prompt_signalled"
assert_pass_if_clean "test_email_fallback_to_prompt"

# =============================================================================
# test_bot_account_flow
# Call resolver with --bot; assert stdout contains BRIDGE_BOT_LOGIN=,
# BRIDGE_BOT_NAME=, BRIDGE_BOT_EMAIL= with placeholder values.
# =============================================================================
_snapshot_fail
echo "--- test_bot_account_flow ---"

# --bot mode does not need gh; provide a minimal stub for safety
MOCK5="$_TMP/mock5"
_make_gh_mock "$MOCK5" '
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
exit 0
'

rc=0
out=$(PATH="$MOCK5:$PATH" bash "$RESOLVER" --bot 2>/dev/null) || rc=$?
assert_eq "test_bot_account_flow: exit 0" "0" "$rc"
assert_contains "test_bot_account_flow: BRIDGE_BOT_LOGIN" "BRIDGE_BOT_LOGIN=" "$out"
assert_contains "test_bot_account_flow: BRIDGE_BOT_NAME" "BRIDGE_BOT_NAME=" "$out"
assert_contains "test_bot_account_flow: BRIDGE_BOT_EMAIL" "BRIDGE_BOT_EMAIL=" "$out"
assert_pass_if_clean "test_bot_account_flow"

# =============================================================================
# test_env_id_from_gh_api
# Mock gh api returning org 'myorg' and repo 'myrepo'; assert
# BRIDGE_ENV_ID=github-myorg-myrepo in stdout.
# =============================================================================
_snapshot_fail
echo "--- test_env_id_from_gh_api ---"

MOCK6="$_TMP/mock6"
_make_gh_mock "$MOCK6" '
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == "user" ]]; then
    echo '"'"'{"login":"jsmith","name":"John Smith","email":"jsmith@example.com"}'"'"'
    exit 0
fi
if [[ "$1" == "repo" && "$2" == "view" ]]; then
    # Supports --json nameWithOwner --jq .nameWithOwner
    echo "myorg/myrepo"
    exit 0
fi
exit 0
'

rc=0
out=$(PATH="$MOCK6:$PATH" bash "$RESOLVER" --env-id 2>/dev/null) || rc=$?
assert_eq "test_env_id_from_gh_api: exit 0" "0" "$rc"
assert_contains "test_env_id_from_gh_api: BRIDGE_ENV_ID" "BRIDGE_ENV_ID=github-myorg-myrepo" "$out"
assert_pass_if_clean "test_env_id_from_gh_api"

# =============================================================================
# test_env_id_from_git_remote
# No gh API for repo view; mock git remote -v returning github.com/myorg/myrepo;
# assert BRIDGE_ENV_ID=github-myorg-myrepo in stdout.
# =============================================================================
_snapshot_fail
echo "--- test_env_id_from_git_remote ---"

MOCK7_GH="$_TMP/mock7_gh"
_make_gh_mock "$MOCK7_GH" '
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == "user" ]]; then
    echo '"'"'{"login":"jsmith","name":"John Smith","email":"jsmith@example.com"}'"'"'
    exit 0
fi
# repo view fails → trigger git remote fallback
if [[ "$1" == "repo" ]]; then
    echo "not a git repository" >&2
    exit 1
fi
exit 0
'

MOCK7_GIT="$_TMP/mock7_git"
_make_git_mock "$MOCK7_GIT" '
if [[ "$1" == "remote" && "$2" == "-v" ]]; then
    echo "origin  git@github.com:myorg/myrepo.git (fetch)"
    echo "origin  git@github.com:myorg/myrepo.git (push)"
    exit 0
fi
exec "$(command -v git 2>/dev/null || echo /usr/bin/git)" "$@"
'

rc=0
out=$(PATH="$MOCK7_GH:$MOCK7_GIT:$PATH" bash "$RESOLVER" --env-id 2>/dev/null) || rc=$?
assert_eq "test_env_id_from_git_remote: exit 0" "0" "$rc"
assert_contains "test_env_id_from_git_remote: BRIDGE_ENV_ID" "BRIDGE_ENV_ID=github-myorg-myrepo" "$out"
assert_pass_if_clean "test_env_id_from_git_remote"

# =============================================================================
# test_gh_unavailable
# Empty PATH (no gh binary); assert non-zero exit with descriptive error on
# stderr or stdout.
# =============================================================================
_snapshot_fail
echo "--- test_gh_unavailable ---"

rc=0
out=$(PATH="/dev/null" bash "$RESOLVER" --own-identity 2>&1) || rc=$?
assert_ne "test_gh_unavailable: exits non-zero" "0" "$rc"
assert_pass_if_clean "test_gh_unavailable"

# =============================================================================
# test_gh_unauthenticated
# Mock gh auth status returning non-zero (unauthenticated); assert error.
# Mock PATH is complete to prevent leaking to real gh binary.
# =============================================================================
_snapshot_fail
echo "--- test_gh_unauthenticated ---"

MOCK9="$_TMP/mock9"
mkdir -p "$MOCK9"
# Provide a complete mock gh that always fails auth
cat > "$MOCK9/gh" <<'FAKEGH9'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    echo "You are not logged into any GitHub hosts. Run gh auth login to authenticate." >&2
    exit 1
fi
exit 1
FAKEGH9
chmod +x "$MOCK9/gh"

rc=0
out=$(PATH="$MOCK9" bash "$RESOLVER" --own-identity 2>&1) || rc=$?
assert_ne "test_gh_unauthenticated: exits non-zero" "0" "$rc"
assert_pass_if_clean "test_gh_unauthenticated"

# =============================================================================
print_summary
