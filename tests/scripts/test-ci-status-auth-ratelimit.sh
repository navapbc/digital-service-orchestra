#!/usr/bin/env bash
# tests/scripts/test-ci-status-auth-ratelimit.sh
# Behavioral tests for auth pre-flight, rate-limit detection, and max-iteration
# ceiling in scripts/ci-status.sh.
#
# All tests invoke ci-status.sh with stubbed gh/git/sleep binaries to verify
# actual behavior rather than grepping source code.
#
# Usage: bash tests/scripts/test-ci-status-auth-ratelimit.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

CI_STATUS_SH="$DSO_PLUGIN_DIR/scripts/ci-status.sh"

echo "=== test-ci-status-auth-ratelimit.sh ==="

_TMP=$(mktemp -d)
trap 'rm -rf "$_TMP"' EXIT

# ── Shared: fake sleep (instant) ─────────────────────────────────────────
FAKE_SLEEP_DIR="$_TMP/fake-sleep"
mkdir -p "$FAKE_SLEEP_DIR"
cat > "$FAKE_SLEEP_DIR/sleep" <<'FAKESLEEP'
#!/usr/bin/env bash
exit 0
FAKESLEEP
chmod +x "$FAKE_SLEEP_DIR/sleep"

# ── Shared: fake git (returns fake SHA and repo root) ────────────────────
FAKE_GIT_DIR="$_TMP/fake-git"
mkdir -p "$FAKE_GIT_DIR"
cat > "$FAKE_GIT_DIR/git" <<'FAKEGIT'
#!/usr/bin/env bash
if [[ "$1" == "ls-remote" ]]; then
    echo "abc123def456    refs/heads/main"
    exit 0
fi
if [[ "$1" == "rev-parse" ]]; then
    if [[ "${2:-}" == "--show-toplevel" ]]; then
        echo "/tmp/fake-repo"
        exit 0
    fi
    echo "abc123def456"
    exit 0
fi
exit 0
FAKEGIT
chmod +x "$FAKE_GIT_DIR/git"

# =============================================================================
# Test 1: Auth failure exits non-zero with clear error message
# =============================================================================
FAKE_GH_AUTH="$_TMP/fake-gh-auth"
mkdir -p "$FAKE_GH_AUTH"
cat > "$FAKE_GH_AUTH/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then
    echo "You are not logged into any GitHub hosts. Run gh auth login to authenticate." >&2
    exit 1
fi
if [[ "$1" == "run" ]]; then echo "[]"; fi
exit 0
FAKEGH
chmod +x "$FAKE_GH_AUTH/gh"

auth_exit=0
result=$(PATH="$FAKE_GH_AUTH:$PATH" bash "$CI_STATUS_SH" 2>&1) || auth_exit=$?

assert_ne "test_auth_failure_exits_nonzero" "0" "$auth_exit"
assert_contains "test_auth_failure_mentions_auth" "auth" "$result"

# =============================================================================
# Test 2: Max iterations ceiling causes exit (not infinite loop)
# Stub gh to always return in_progress. The script should exit after
# MAX_POLL_ITERATIONS, not loop forever.
# =============================================================================
CALL_COUNT_FILE="$_TMP/gh_call_count.txt"
echo "0" > "$CALL_COUNT_FILE"

FAKE_GH_LOOP="$_TMP/fake-gh-loop"
mkdir -p "$FAKE_GH_LOOP"
cat > "$FAKE_GH_LOOP/gh" <<FAKEGH2
#!/usr/bin/env bash
_count=\$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
_count=\$(( _count + 1 ))
echo "\$_count" > "$CALL_COUNT_FILE"

if [[ "\$1 \$2" == "auth status" ]]; then
    echo "Logged in to github.com as testuser" >&2
    exit 0
fi
if [[ "\$1" == "ls-remote" ]]; then exit 0; fi
if [[ "\$1" == "run" && "\$2" == "list" ]]; then
    echo '[{"databaseId":12345,"status":"in_progress","conclusion":null,"name":"CI","startedAt":"2020-01-01T00:00:00Z","createdAt":"2020-01-01T00:00:00Z","headSha":"abc123def456"}]'
    exit 0
fi
if [[ "\$1" == "run" && "\$2" == "view" ]]; then
    echo '{"status":"in_progress","conclusion":null,"name":"CI"}'
    exit 0
fi
exit 0
FAKEGH2
chmod +x "$FAKE_GH_LOOP/gh"

iter_result=0
timeout 30 bash -c "
    PATH='$FAKE_SLEEP_DIR:$FAKE_GH_LOOP:$FAKE_GIT_DIR':\$PATH
    export PATH
    bash '$CI_STATUS_SH' --wait --skip-regression-check --branch main 2>&1
" > "$_TMP/iter_output.txt" 2>&1 || iter_result=$?

_iter_output=$(cat "$_TMP/iter_output.txt" 2>/dev/null || echo "")

assert_ne "test_max_iter_exits_nonzero" "0" "$iter_result"

# Should not have hit our 30s watchdog (exit 124 = timeout killed it)
_watchdog_timeout=0
[[ "$iter_result" == "124" ]] && _watchdog_timeout=1
assert_eq "test_max_iter_not_watchdog" "0" "$_watchdog_timeout"

assert_contains "test_max_iter_mentions_timeout" "TIMEOUT" "$_iter_output"

# =============================================================================
# Test 3: Successful CI returns exit 0 with success status
# =============================================================================
FAKE_GH_OK="$_TMP/fake-gh-ok"
mkdir -p "$FAKE_GH_OK"
cat > "$FAKE_GH_OK/gh" <<'FAKEOK'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then echo "Logged in" >&2; exit 0; fi
if [[ "$1" == "run" && "$2" == "list" ]]; then
    echo '[{"databaseId":1,"status":"completed","conclusion":"success","name":"CI","startedAt":"2020-01-01T00:00:00Z","createdAt":"2020-01-01T00:00:00Z","headSha":"abc123def456"}]'
    exit 0
fi
if [[ "$1" == "run" && "$2" == "view" ]]; then
    echo '{"status":"completed","conclusion":"success","name":"CI"}'
    exit 0
fi
exit 0
FAKEOK
chmod +x "$FAKE_GH_OK/gh"

ok_result=0
ok_output=$(PATH="$FAKE_GH_OK:$FAKE_GIT_DIR:$PATH" bash "$CI_STATUS_SH" --wait --skip-regression-check --branch main 2>&1) || ok_result=$?

assert_eq "test_success_exits_zero" "0" "$ok_result"
assert_contains "test_success_reports_success" "success" "$ok_output"

# =============================================================================
print_summary
