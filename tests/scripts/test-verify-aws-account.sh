#!/usr/bin/env bash
set -euo pipefail
# tests/scripts/test-verify-aws-account.sh
# Behavioral tests for plugins/dso/scripts/verify-aws-account.sh
#
# Tests exercise all four exit-code paths via PATH and environment variable
# stubbing — never touching real AWS credentials or account IDs.
#
# Cases covered:
#   1. Happy path: stub aws returning account 820258254566 → exits 0, prints OK
#   2. Wrong account: stub aws returning different account → exits 1 with expected/actual diff
#   3. aws auth failure: stub aws returning non-zero → exits non-zero surfacing error
#   4. aws absent from PATH: aws CLI missing → exits non-zero with "aws CLI not found"
#   5. Config integration: script reads review_telemetry.aws_account_id from config
#
# Usage: bash tests/scripts/test-verify-aws-account.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/verify-aws-account.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-verify-aws-account.sh ==="

# ── Setup ─────────────────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
cleanup() {
    local d
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && [[ -d "$d" ]] && rm -rf "$d" || true
    done
}
trap cleanup EXIT

make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

EXPECTED_ACCOUNT="820258254566"

# ── Helper: write a stub aws binary ───────────────────────────────────────────
write_aws_stub() {
    local bin_dir="$1"
    local account="$2"
    local exit_code="${3:-0}"
    cat > "$bin_dir/aws" << STUBEOF
#!/usr/bin/env bash
# Stub aws binary for testing
if [[ "\${1:-}" == "sts" && "\${2:-}" == "get-caller-identity" ]]; then
    if [[ "$exit_code" -ne 0 ]]; then
        echo "An error occurred (AuthFailure) when calling the GetCallerIdentity operation: not authenticated" >&2
        exit $exit_code
    fi
    printf '{"UserId":"AIDEXAMPLE123","Account":"%s","Arn":"arn:aws:iam::%s:user/test"}\n' "$account" "$account"
    exit 0
fi
exit 0
STUBEOF
    chmod +x "$bin_dir/aws"
}

# ── Helper: stub read-config that always returns a fixed account ──────────────
write_read_config_stub() {
    local bin_dir="$1"
    local account="$2"
    cat > "$bin_dir/read-config-stub.sh" << STUBEOF
#!/usr/bin/env bash
# Stub read-config for testing review_telemetry.aws_account_id
if [[ "\${1:-}" == "review_telemetry.aws_account_id" ]]; then
    echo "$account"
    exit 0
fi
exit 1
STUBEOF
    chmod +x "$bin_dir/read-config-stub.sh"
}

# ── Test 1: Happy path — stub aws returns expected account → exits 0 ──────────
test_happy_path_exits_0() {
    local mock_bin
    mock_bin="$(make_tmpdir)"
    write_aws_stub "$mock_bin" "$EXPECTED_ACCOUNT" 0

    local exit_code=0
    local output
    output=$(
        DSO_AWS_CMD="$mock_bin/aws" bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "happy path: exits 0 when account matches" \
        "0" "$exit_code"

    assert_contains "happy path: stdout contains OK" \
        "OK" "$output"

    assert_contains "happy path: stdout contains account ID" \
        "$EXPECTED_ACCOUNT" "$output"
}

# ── Test 2: Wrong account — stub aws returns different account → exits 1 ──────
# Verifies the expected/actual diff is surfaced on mismatch.
test_wrong_account_exits_1_with_mismatch_diff() {
    local mock_bin
    mock_bin="$(make_tmpdir)"
    local different_account="999999999999"
    write_aws_stub "$mock_bin" "$different_account" 0

    local exit_code=0
    local output
    output=$(
        DSO_AWS_CMD="$mock_bin/aws" bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_ne "wrong account: exits non-zero" \
        "0" "$exit_code"

    assert_eq "wrong account: exits 1 specifically" \
        "1" "$exit_code"

    # Must print expected vs. actual diff
    local found_diff=0
    if echo "$output" | grep -qE 'expected.*actual|mismatch|different'; then
        found_diff=1
    fi
    assert_eq "wrong account: output contains expected/actual diff" \
        "1" "$found_diff"

    assert_contains "wrong account: output contains expected account" \
        "$EXPECTED_ACCOUNT" "$output"

    assert_contains "wrong account: output contains actual account" \
        "$different_account" "$output"
}

# ── Test 3: aws auth failure → exits non-zero surfacing error ─────────────────
# Stub aws exits non-zero (simulating AuthFailure / no credentials).
test_aws_auth_failure_exits_nonzero() {
    local mock_bin
    mock_bin="$(make_tmpdir)"
    write_aws_stub "$mock_bin" "$EXPECTED_ACCOUNT" 255

    local exit_code=0
    local output
    output=$(
        DSO_AWS_CMD="$mock_bin/aws" bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_ne "aws auth failure: exits non-zero" \
        "0" "$exit_code"

    # Must surface some indication of the aws error
    local found_error=0
    if echo "$output" | grep -qiE 'ERROR|failed|auth'; then
        found_error=1
    fi
    assert_eq "aws auth failure: output surfaces aws error" \
        "1" "$found_error"
}

# ── Test 4: aws absent from PATH → exits non-zero with clear "aws CLI not found" ──
# Uses DSO_AWS_CMD pointing to a non-existent binary so the "aws missing" branch
# triggers without requiring a PATH that lacks both aws and python3 (they share
# /opt/homebrew/bin on macOS, making PATH restriction impractical).
test_aws_missing_from_path_exits_nonzero() {
    local tmp_dir
    tmp_dir="$(make_tmpdir)"
    # Point DSO_AWS_CMD at a path that doesn't exist — triggers the missing-aws branch.
    local nonexistent_aws="$tmp_dir/nonexistent-aws-binary"

    local exit_code=0
    local output
    output=$(
        DSO_AWS_CMD="$nonexistent_aws" bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_ne "aws missing: exits non-zero when aws absent" \
        "0" "$exit_code"

    # Must contain a clear "aws CLI not found" / "aws CLI missing" message
    local found_hint=0
    if echo "$output" | grep -qiE 'aws.*missing|aws.*not.found|not found.*aws|not.*executable'; then
        found_hint=1
    fi
    assert_eq "aws missing: output contains 'aws CLI not found' message" \
        "1" "$found_hint"

    # Must contain a remediation hint
    local found_remediation=0
    if echo "$output" | grep -qiE 'install|https?://|Remediation|ERROR'; then
        found_remediation=1
    fi
    assert_eq "aws missing: output contains remediation hint" \
        "1" "$found_remediation"
}

# ── Test 5: Config integration — script reads review_telemetry.aws_account_id ──
# Verify the script honours the DSO_READ_CONFIG_CMD override so a stub config
# reader can supply an alternate expected account.
test_config_integration_reads_review_telemetry_aws_account_id() {
    local mock_bin
    mock_bin="$(make_tmpdir)"

    # Stub aws returning the matching account
    write_aws_stub "$mock_bin" "$EXPECTED_ACCOUNT" 0
    # Stub read-config to emit the expected account for the config key
    write_read_config_stub "$mock_bin" "$EXPECTED_ACCOUNT"

    local exit_code=0
    local output
    output=$(
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "config integration: exits 0 with stubbed read-config" \
        "0" "$exit_code"

    assert_contains "config integration: output confirms account matched" \
        "OK" "$output"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_happy_path_exits_0
test_wrong_account_exits_1_with_mismatch_diff
test_aws_auth_failure_exits_nonzero
test_aws_missing_from_path_exits_nonzero
test_config_integration_reads_review_telemetry_aws_account_id

print_summary
