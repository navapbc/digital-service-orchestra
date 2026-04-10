#!/usr/bin/env bash
# tests/scripts/test-figma-api-fetch.sh
# Behavioral tests for plugins/dso/scripts/figma-api-fetch.sh
#
# Tests use PATH override with a mock curl to avoid real HTTP calls.
# FIGMA_API_BASE_URL is overridden to control which URL the script targets.
#
# Usage: bash tests/scripts/test-figma-api-fetch.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/figma-api-fetch.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-figma-api-fetch.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# ── Script existence check ────────────────────────────────────────────────────
if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: figma-api-fetch.sh not found at $SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

# =============================================================================
# FA-1: Valid file key and PAT → curl invoked with correct header and URL
# =============================================================================
echo ""
echo "--- test_fa_1_curl_invoked_with_correct_header_and_url ---"
_snapshot_fail

# Mock curl: records args to a file, emits a valid JSON body, exits 0
CURL_ARGS_FILE="$TMPDIR_TEST/fa1_curl_args.txt"
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
echo "\$@" > "$CURL_ARGS_FILE"
printf '{"document":{}}'
exit 0
MOCKCURL
chmod +x "$MOCK_BIN/curl"

FA1_OUTPUT_FILE="$TMPDIR_TEST/fa1_output.json"
fa1_exit=0
fa1_stderr=$(
    FIGMA_API_BASE_URL="https://api.figma.com" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" "TESTFILEKEY123" "$FA1_OUTPUT_FILE" 2>&1
) || fa1_exit=$?

fa1_curl_args="$(cat "$CURL_ARGS_FILE" 2>/dev/null || echo "")"

assert_eq "fa1_exit_code" "0" "$fa1_exit"
assert_contains "fa1_curl_has_x_figma_token_header" "X-Figma-Token" "$fa1_curl_args"
assert_contains "fa1_curl_has_v1_files_path" "/v1/files/TESTFILEKEY123" "$fa1_curl_args"
assert_contains "fa1_curl_targets_figma_api" "api.figma.com" "$fa1_curl_args"

assert_pass_if_clean "test_fa_1_curl_invoked_with_correct_header_and_url"

# =============================================================================
# FA-2: 401/403 response → exit 1 with PAT error message on stderr
# =============================================================================
echo ""
echo "--- test_fa_2_401_response_exits_1_with_pat_error ---"
_snapshot_fail

# Subtest 2a: 401
cat > "$MOCK_BIN/curl" <<'MOCKCURL'
#!/usr/bin/env bash
# Emit HTTP 401 response; figma-api-fetch.sh must detect auth failure
echo '{"status":401,"err":"Invalid token"}'
exit 0
MOCKCURL
chmod +x "$MOCK_BIN/curl"

fa2a_exit=0
fa2a_stderr=$(
    FIGMA_API_BASE_URL="https://api.figma.com" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" "FILEKEY401" "$TMPDIR_TEST/fa2a_output.json" 2>&1
) || fa2a_exit=$?

assert_ne "fa2a_exit_nonzero_on_401" "0" "$fa2a_exit"
assert_contains "fa2a_stderr_mentions_pat" "PAT" "$fa2a_stderr"

# Subtest 2b: 403
cat > "$MOCK_BIN/curl" <<'MOCKCURL'
#!/usr/bin/env bash
echo '{"status":403,"err":"Forbidden"}'
exit 0
MOCKCURL
chmod +x "$MOCK_BIN/curl"

fa2b_exit=0
fa2b_stderr=$(
    FIGMA_API_BASE_URL="https://api.figma.com" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" "FILEKEY403" "$TMPDIR_TEST/fa2b_output.json" 2>&1
) || fa2b_exit=$?

assert_ne "fa2b_exit_nonzero_on_403" "0" "$fa2b_exit"
assert_contains "fa2b_stderr_mentions_pat" "PAT" "$fa2b_stderr"

assert_pass_if_clean "test_fa_2_401_response_exits_1_with_pat_error"

# =============================================================================
# FA-3: Network timeout (curl exit 28) → exit 1 with network error on stderr
# =============================================================================
echo ""
echo "--- test_fa_3_network_timeout_exits_1_with_network_error ---"
_snapshot_fail

cat > "$MOCK_BIN/curl" <<'MOCKCURL'
#!/usr/bin/env bash
# Simulate curl network timeout (exit 28)
exit 28
MOCKCURL
chmod +x "$MOCK_BIN/curl"

fa3_exit=0
fa3_stderr=$(
    FIGMA_API_BASE_URL="https://api.figma.com" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" "FILEKEYTIMEOUT" "$TMPDIR_TEST/fa3_output.json" 2>&1
) || fa3_exit=$?

assert_ne "fa3_exit_nonzero_on_timeout" "0" "$fa3_exit"
assert_contains "fa3_stderr_mentions_network" "network" "$fa3_stderr"

assert_pass_if_clean "test_fa_3_network_timeout_exits_1_with_network_error"

# =============================================================================
# FA-4: Depth limiting — default depth 4, configurable via FIGMA_FETCH_DEPTH
# =============================================================================
echo ""
echo "--- test_fa_4_depth_parameter_included_in_url ---"
_snapshot_fail

CURL_ARGS_FA4_FILE="$TMPDIR_TEST/fa4_curl_args.txt"
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
echo "\$@" > "$CURL_ARGS_FA4_FILE"
printf '{"document":{}}'
exit 0
MOCKCURL
chmod +x "$MOCK_BIN/curl"

FA4_OUTPUT_FILE="$TMPDIR_TEST/fa4_output.json"

# Subtest 4a: default depth 4
fa4a_exit=0
fa4a_stderr=$(
    FIGMA_API_BASE_URL="https://api.figma.com" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" "FILEKEYDEPTH" "$FA4_OUTPUT_FILE" 2>&1
) || fa4a_exit=$?

fa4a_curl_args="$(cat "$CURL_ARGS_FA4_FILE" 2>/dev/null || echo "")"

assert_eq "fa4a_exit_code" "0" "$fa4a_exit"
assert_contains "fa4a_default_depth_4" "depth=4" "$fa4a_curl_args"

# Subtest 4b: custom depth via FIGMA_FETCH_DEPTH
fa4b_exit=0
fa4b_stderr=$(
    FIGMA_API_BASE_URL="https://api.figma.com" \
    FIGMA_FETCH_DEPTH="2" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" "FILEKEYDEPTH" "$FA4_OUTPUT_FILE" 2>&1
) || fa4b_exit=$?

fa4b_curl_args="$(cat "$CURL_ARGS_FA4_FILE" 2>/dev/null || echo "")"

assert_eq "fa4b_exit_code" "0" "$fa4b_exit"
assert_contains "fa4b_custom_depth_2" "depth=2" "$fa4b_curl_args"

assert_pass_if_clean "test_fa_4_depth_parameter_included_in_url"

# =============================================================================
# FA-5: Valid response → JSON written to output file path, exit 0
# =============================================================================
echo ""
echo "--- test_fa_5_json_written_to_output_file ---"
_snapshot_fail

EXPECTED_JSON='{"document":{"type":"DOCUMENT","name":"Test File"}}'
CURL_ARGS_FA5_FILE="$TMPDIR_TEST/fa5_curl_args.txt"
cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
echo "\$@" > "$CURL_ARGS_FA5_FILE"
printf '%s' '$EXPECTED_JSON'
exit 0
MOCKCURL
chmod +x "$MOCK_BIN/curl"

FA5_OUTPUT_FILE="$TMPDIR_TEST/fa5_output.json"
fa5_exit=0
fa5_stderr=$(
    FIGMA_API_BASE_URL="https://api.figma.com" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" "FILEKEYOUTPUT" "$FA5_OUTPUT_FILE" 2>&1
) || fa5_exit=$?

assert_eq "fa5_exit_code" "0" "$fa5_exit"
assert_eq "fa5_output_file_exists" "1" "$([ -f "$FA5_OUTPUT_FILE" ] && echo 1 || echo 0)"

# Output file should contain the JSON response body
fa5_file_contents="$(cat "$FA5_OUTPUT_FILE" 2>/dev/null || echo "")"
assert_ne "fa5_output_file_nonempty" "" "$fa5_file_contents"

assert_pass_if_clean "test_fa_5_json_written_to_output_file"

# =============================================================================
# FA-5b: --output flag variant
# =============================================================================
echo ""
echo "--- test_fa_5b_output_flag_variant ---"
_snapshot_fail

cat > "$MOCK_BIN/curl" <<MOCKCURL
#!/usr/bin/env bash
printf '{"document":{}}'
exit 0
MOCKCURL
chmod +x "$MOCK_BIN/curl"

FA5B_OUTPUT_FILE="$TMPDIR_TEST/fa5b_output.json"
fa5b_exit=0
fa5b_stderr=$(
    FIGMA_API_BASE_URL="https://api.figma.com" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$SCRIPT" "FILEKEYOUTPUT" --output "$FA5B_OUTPUT_FILE" 2>&1
) || fa5b_exit=$?

assert_eq "fa5b_exit_code" "0" "$fa5b_exit"
assert_eq "fa5b_output_file_exists" "1" "$([ -f "$FA5B_OUTPUT_FILE" ] && echo 1 || echo 0)"

assert_pass_if_clean "test_fa_5b_output_flag_variant"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
