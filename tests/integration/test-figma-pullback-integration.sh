#!/usr/bin/env bash
# tests/integration/test-figma-pullback-integration.sh
# Integration tests for Figma URL parsing and PAT authentication.
#
# Tests: FP-URL-1 through FP-URL-4 (URL parsing), FP-AUTH-1 through FP-AUTH-3 (PAT auth)
#
# RED state: These tests MUST FAIL until figma-url-parse.sh and figma-auth.sh are implemented.
# Script-not-found is the expected failure mode — do NOT skip on missing scripts.
#
# Usage: bash tests/integration/test-figma-pullback-integration.sh
# Returns: exit 0 if all pass, exit 1 if any fail (RED state expected until implementation)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-figma-pullback-integration.sh ==="

# Cleanup trap — removes temp dirs and any figma lock files created during test execution
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
    # Remove any figma lock files created during test execution
    rm -f /tmp/figma-auth.lock /tmp/figma-pullback.lock 2>/dev/null || true
}
trap _cleanup EXIT

# Script paths under test (do NOT create these — they must not exist for RED state)
FIGMA_URL_PARSE="$REPO_ROOT/plugins/dso/scripts/figma-url-parse.sh"
FIGMA_AUTH="$REPO_ROOT/plugins/dso/scripts/figma-auth.sh"

# Fixtures
FIXTURES_DIR="$SCRIPT_DIR/fixtures/figma"

# ---------------------------------------------------------------------------
# URL Parsing Tests (FP-URL-1 through FP-URL-4)
# ---------------------------------------------------------------------------

# FP-URL-1: Given a /design/-format URL, when figma-url-parse.sh processes it,
# then file key is extracted to stdout and exits 0.
test_fp_url_1_design_format() {
    local url="https://www.figma.com/design/AbCdEfGhIjKl0123/My-Design-File?node-id=2%3A1"
    local expected_key="AbCdEfGhIjKl0123"

    # Script-not-found must FAIL (exit 1), not skip
    if [[ ! -f "$FIGMA_URL_PARSE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-URL-1 — figma-url-parse.sh not found at %s\n" "$FIGMA_URL_PARSE" >&2
        return
    fi

    local output exit_code=0
    output=$(bash "$FIGMA_URL_PARSE" "$url" 2>/dev/null) || exit_code=$?

    assert_eq "FP-URL-1: exits 0 for /design/ URL" "0" "$exit_code"
    assert_eq "FP-URL-1: extracts file key to stdout" "$expected_key" "$output"
}

# FP-URL-2: Given a /file/-format URL, when figma-url-parse.sh processes it,
# then file key extracted, exits 0.
test_fp_url_2_file_format() {
    local url="https://www.figma.com/file/XyZ9876abcDEF321/Legacy-File?node-id=0%3A1"
    local expected_key="XyZ9876abcDEF321"

    if [[ ! -f "$FIGMA_URL_PARSE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-URL-2 — figma-url-parse.sh not found at %s\n" "$FIGMA_URL_PARSE" >&2
        return
    fi

    local output exit_code=0
    output=$(bash "$FIGMA_URL_PARSE" "$url" 2>/dev/null) || exit_code=$?

    assert_eq "FP-URL-2: exits 0 for /file/ URL" "0" "$exit_code"
    assert_eq "FP-URL-2: extracts file key to stdout" "$expected_key" "$output"
}

# FP-URL-3: Given a /proto/-format URL, when figma-url-parse.sh processes it,
# then file key extracted, exits 0.
test_fp_url_3_proto_format() {
    local url="https://www.figma.com/proto/Mn0pQrStUvWx1234/Prototype-Flow?node-id=1%3A2"
    local expected_key="Mn0pQrStUvWx1234"

    if [[ ! -f "$FIGMA_URL_PARSE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-URL-3 — figma-url-parse.sh not found at %s\n" "$FIGMA_URL_PARSE" >&2
        return
    fi

    local output exit_code=0
    output=$(bash "$FIGMA_URL_PARSE" "$url" 2>/dev/null) || exit_code=$?

    assert_eq "FP-URL-3: exits 0 for /proto/ URL" "0" "$exit_code"
    assert_eq "FP-URL-3: extracts file key to stdout" "$expected_key" "$output"
}

# FP-URL-4: Given an invalid URL (no Figma domain, no key), when figma-url-parse.sh
# processes it, then exits 1 with error message on stderr.
test_fp_url_4_invalid_url() {
    local url="https://example.com/not-a-figma-url"

    if [[ ! -f "$FIGMA_URL_PARSE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-URL-4 — figma-url-parse.sh not found at %s\n" "$FIGMA_URL_PARSE" >&2
        return
    fi

    local stderr_output exit_code=0
    stderr_output=$(bash "$FIGMA_URL_PARSE" "$url" 2>&1 >/dev/null) || exit_code=$?

    assert_ne "FP-URL-4: exits non-zero for invalid URL" "0" "$exit_code"
    assert_ne "FP-URL-4: emits error message on stderr" "" "$stderr_output"
}

# ---------------------------------------------------------------------------
# PAT Authentication Tests (FP-AUTH-1 through FP-AUTH-3)
# ---------------------------------------------------------------------------

# FP-AUTH-1: Given a valid PAT, when figma-auth.sh validates via GET /v1/me,
# then exits 0.
# Uses a mock HTTP server approach: we intercept with FIGMA_API_BASE_URL pointing
# to a local endpoint. If mock infrastructure unavailable, we stub with a temp
# server or rely on a known-valid fixture.
#
# For RED tests, the script must not exist yet — this test will FAIL on script-not-found.
test_fp_auth_1_valid_pat() {
    if [[ ! -f "$FIGMA_AUTH" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-AUTH-1 — figma-auth.sh not found at %s\n" "$FIGMA_AUTH" >&2
        return
    fi

    # Use a mock server via Python's http.server if available
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Create a mock /v1/me success response
    local mock_response_dir="$tmpdir/v1"
    mkdir -p "$mock_response_dir"
    cat > "$mock_response_dir/me" <<'JSON'
{"id":"123456","email":"test@example.com","handle":"testuser","img_url":""}
JSON

    # Start a minimal mock HTTP server
    local mock_port=18741
    python3 -m http.server "$mock_port" --directory "$tmpdir" >/dev/null 2>&1 &
    local server_pid=$!
    # Give server time to start
    sleep 0.3

    local exit_code=0
    FIGMA_PAT="figd_validpatvalue123456" \
    FIGMA_API_BASE_URL="http://localhost:$mock_port" \
        bash "$FIGMA_AUTH" 2>/dev/null || exit_code=$?

    kill "$server_pid" 2>/dev/null || true

    assert_eq "FP-AUTH-1: exits 0 with valid PAT and successful /v1/me response" "0" "$exit_code"
}

# FP-AUTH-2: Given an invalid PAT, when figma-auth.sh validates, then exits 1 with
# re-provisioning instructions on stderr.
test_fp_auth_2_invalid_pat() {
    if [[ ! -f "$FIGMA_AUTH" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-AUTH-2 — figma-auth.sh not found at %s\n" "$FIGMA_AUTH" >&2
        return
    fi

    # Use fixture: figma-401-response.json (status 403, simulates auth failure)
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Create mock server serving 403 response
    local mock_v1_dir="$tmpdir/v1"
    mkdir -p "$mock_v1_dir"
    cp "$FIXTURES_DIR/figma-401-response.json" "$mock_v1_dir/me"

    local mock_port=18742
    python3 -m http.server "$mock_port" --directory "$tmpdir" >/dev/null 2>&1 &
    local server_pid=$!
    sleep 0.3

    local stderr_output exit_code=0
    stderr_output=$(FIGMA_PAT="figd_invalidtoken000" \
        FIGMA_API_BASE_URL="http://localhost:$mock_port" \
        bash "$FIGMA_AUTH" 2>&1 >/dev/null) || exit_code=$?

    kill "$server_pid" 2>/dev/null || true

    assert_ne "FP-AUTH-2: exits non-zero with invalid PAT" "0" "$exit_code"
    assert_ne "FP-AUTH-2: emits re-provisioning instructions on stderr" "" "$stderr_output"
}

# FP-AUTH-3: Given FIGMA_PAT env var and no config key, when figma-auth.sh runs,
# then reads PAT from env var (env-var fallback).
# Verifies the script uses FIGMA_PAT env var when no config key is present.
test_fp_auth_3_env_var_fallback() {
    if [[ ! -f "$FIGMA_AUTH" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-AUTH-3 — figma-auth.sh not found at %s\n" "$FIGMA_AUTH" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Point to a temp config dir with NO figma PAT config key
    local mock_config_dir="$tmpdir/config"
    mkdir -p "$mock_config_dir"
    # Create an empty config file (no FIGMA_PAT key)
    touch "$mock_config_dir/dso-config.conf"

    # Create mock server serving success response for /v1/me
    local mock_v1_dir="$tmpdir/v1"
    mkdir -p "$mock_v1_dir"
    cat > "$mock_v1_dir/me" <<'JSON'
{"id":"789012","email":"envuser@example.com","handle":"envuser","img_url":""}
JSON

    local mock_port=18743
    python3 -m http.server "$mock_port" --directory "$tmpdir" >/dev/null 2>&1 &
    local server_pid=$!
    sleep 0.3

    local exit_code=0
    FIGMA_PAT="figd_envvartoken987654" \
    FIGMA_API_BASE_URL="http://localhost:$mock_port" \
    DSO_CONFIG_FILE="$mock_config_dir/dso-config.conf" \
        bash "$FIGMA_AUTH" 2>/dev/null || exit_code=$?

    kill "$server_pid" 2>/dev/null || true

    assert_eq "FP-AUTH-3: exits 0 when PAT read from FIGMA_PAT env var (no config key)" "0" "$exit_code"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_fp_url_1_design_format
test_fp_url_2_file_format
test_fp_url_3_proto_format
test_fp_url_4_invalid_url
test_fp_auth_1_valid_pat
test_fp_auth_2_invalid_pat
test_fp_auth_3_env_var_fallback

print_summary
