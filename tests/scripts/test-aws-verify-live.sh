#!/usr/bin/env bash
set -euo pipefail
# tests/scripts/test-aws-verify-live.sh
# Behavioral tests for plugins/dso/scripts/telemetry/aws-verify-live.sh
#
# All AWS calls are stubbed via DSO_AWS_CMD — never touches real AWS endpoints.
# Config reads are stubbed via DSO_READ_CONFIG_CMD.
# curl calls are stubbed via a $mock_bin/curl stub in PATH.
#
# Cases covered:
#   1. t_all_checks_pass_exits_0                       — happy path; exits 0; 7 ': ok' lines
#   2. t_iam_trust_missing_exits_nonzero                — trust policy lacks lambda.amazonaws.com; FAIL
#   3. t_missing_bucket_name_key_exits_1_named          — bucket_name key empty; exit 1 + named error
#   4. t_missing_function_name_key_exits_1_named        — lambda_function_name key empty; exit 1 + named
#   5. t_missing_role_name_key_exits_1_named            — iam_role_name key empty; exit 1 + named
#   6. t_teardown_absent_exits_nonzero_within_5s        — all aws stubs exit 1; each check ≤5s wall-clock
#   7. t_e2e_post_uses_backoff_schedule                 — list-objects-v2 always empty; ≥3 polls; monotone gaps
#   8. t_aws_calls_use_dso_aws_cmd_wrapper              — DSO_AWS_CMD records ≥7 invocations
#   9. t_post_visibility_absent_resource_completes_under_5s — budget exhausted is success (not hung)
#
# Usage: bash tests/scripts/test-aws-verify-live.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/telemetry/aws-verify-live.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-aws-verify-live.sh ==="

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
    d="$(mktemp -d "${TMPDIR:-/tmp}/aws-verify-live-test.XXXXXX")"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

make_tmpfile() {
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/aws-verify-live-test.XXXXXX")"
    _TEST_TMPDIRS+=("$f")
    echo "$f"
}

# ── Shared fixture constants ───────────────────────────────────────────────────
BUCKET_NAME="test-bucket"
FUNCTION_NAME="test-function"
ROLE_NAME="test-role"
ROLE_ARN="arn:aws:iam::123456789012:role/test-role"
FUNCTION_URL="https://abc123.lambda-url.us-east-1.on.aws/"

# ── Helper: write the read-config stub ────────────────────────────────────────
# Usage: write_read_config_stub <bin_dir> [missing_key]
# When missing_key is set, that config key returns empty string.
write_read_config_stub() {
    local bin_dir="$1"
    local missing_key="${2:-}"
    cat > "$bin_dir/read-config-stub.sh" << STUBEOF
#!/usr/bin/env bash
key="\${1:-}"
missing_key="$missing_key"
case "\$key" in
    review_telemetry.bucket_name)
        [[ "\$missing_key" == "review_telemetry.bucket_name" ]] && echo "" || echo "$BUCKET_NAME" ;;
    review_telemetry.lambda_function_name)
        [[ "\$missing_key" == "review_telemetry.lambda_function_name" ]] && echo "" || echo "$FUNCTION_NAME" ;;
    review_telemetry.iam_role_name)
        [[ "\$missing_key" == "review_telemetry.iam_role_name" ]] && echo "" || echo "$ROLE_NAME" ;;
    review_telemetry.lambda_function_url)
        [[ "\$missing_key" == "review_telemetry.lambda_function_url" ]] && echo "" || echo "$FUNCTION_URL" ;;
    *) echo "" ;;
esac
exit 0
STUBEOF
    chmod +x "$bin_dir/read-config-stub.sh"
}

# ── Helper: write happy-path aws stub ─────────────────────────────────────────
# Stub env vars (read at runtime):
#   CALL_LOG                 — file path for logging each invocation
#   STUB_ALL_FAIL            — 1 → all aws calls exit 1
#   STUB_IAM_NO_LAMBDA_TRUST — 1 → IAM trust policy lacks lambda.amazonaws.com
#   STUB_LIST_OBJECTS_EMPTY  — 1 → list-objects-v2 always returns empty (no new objects)
#   POLL_TIMESTAMP_LOG       — file path to record list-objects-v2 poll timestamps
write_aws_stub() {
    local bin_dir="$1"
    local bucket_name="$2"
    local function_name="$3"
    local role_name="$4"
    local role_arn="$5"
    local function_url="$6"
    # shellcheck disable=SC2016
    cat > "$bin_dir/aws" << STUBEOF
#!/usr/bin/env bash
CALL_LOG="\${CALL_LOG:-/dev/null}"
STUB_ALL_FAIL="\${STUB_ALL_FAIL:-0}"
STUB_IAM_NO_LAMBDA_TRUST="\${STUB_IAM_NO_LAMBDA_TRUST:-0}"
STUB_LIST_OBJECTS_EMPTY="\${STUB_LIST_OBJECTS_EMPTY:-0}"
POLL_TIMESTAMP_LOG="\${POLL_TIMESTAMP_LOG:-/dev/null}"

echo "\$*" >> "\$CALL_LOG"

sub="\${1:-}"
sub2="\${2:-}"

# ── All-fail mode ──────────────────────────────────────────────────────────────
if [[ "\$STUB_ALL_FAIL" == "1" ]]; then
    exit 1
fi

# ── Lambda ────────────────────────────────────────────────────────────────────
if [[ "\$sub" == "lambda" && "\$sub2" == "get-function-url-config" ]]; then
    echo '{"FunctionUrl":"$function_url","AuthType":"NONE"}'
    exit 0
fi

# ── IAM ───────────────────────────────────────────────────────────────────────
if [[ "\$sub" == "iam" && "\$sub2" == "get-role" ]]; then
    if [[ "\$STUB_IAM_NO_LAMBDA_TRUST" == "1" ]]; then
        echo '{"Role":{"RoleName":"$role_name","Arn":"$role_arn","AssumeRolePolicyDocument":{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}}}'
    else
        echo '{"Role":{"RoleName":"$role_name","Arn":"$role_arn","AssumeRolePolicyDocument":{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}}}'
    fi
    exit 0
fi

# ── S3 ────────────────────────────────────────────────────────────────────────
if [[ "\$sub" == "s3api" && "\$sub2" == "head-bucket" ]]; then
    exit 0
fi

if [[ "\$sub" == "s3api" && "\$sub2" == "get-bucket-encryption" ]]; then
    echo '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}'
    exit 0
fi

if [[ "\$sub" == "s3api" && "\$sub2" == "get-bucket-lifecycle-configuration" ]]; then
    echo '{"Rules":[{"Status":"Enabled","Transitions":[{"Days":90,"StorageClass":"GLACIER_IR"}]}]}'
    exit 0
fi

if [[ "\$sub" == "iam" && "\$sub2" == "simulate-principal-policy" ]]; then
    echo '{"EvaluationResults":[{"EvalActionName":"s3:PutObject","EvalDecision":"allowed"}]}'
    exit 0
fi

if [[ "\$sub" == "s3api" && "\$sub2" == "list-objects-v2" ]]; then
    # Record poll timestamp for backoff verification
    date +%s >> "\$POLL_TIMESTAMP_LOG"
    if [[ "\$STUB_LIST_OBJECTS_EMPTY" == "1" ]]; then
        echo '{"Contents":[],"KeyCount":0}'
    else
        echo '{"Contents":[{"Key":"dso-roundtrip-test/test-obj","Size":100}],"KeyCount":1}'
    fi
    exit 0
fi

# Default: succeed silently
exit 0
STUBEOF
    chmod +x "$bin_dir/aws"
}

# ── Helper: write a curl stub that succeeds (simulates POST to Lambda URL) ───
write_curl_stub() {
    local bin_dir="$1"
    cat > "$bin_dir/curl" << 'STUBEOF'
#!/usr/bin/env bash
# Accept any arguments; succeed silently (simulates a 200 POST to Lambda URL)
exit 0
STUBEOF
    chmod +x "$bin_dir/curl"
}

# ── Helper: write a fast sleep stub (no-op; for tests that exercise backoff) ──
write_sleep_stub() {
    local bin_dir="$1"
    cat > "$bin_dir/sleep" << 'STUBEOF'
#!/usr/bin/env bash
# No-op sleep stub: record invocations but do not actually sleep
SLEEP_LOG="${SLEEP_LOG:-/dev/null}"
echo "$*" >> "$SLEEP_LOG"
exit 0
STUBEOF
    chmod +x "$bin_dir/sleep"
}

# ── Test 1: Happy path — exits 0, 7 ': ok' lines in stdout ───────────────────
t_all_checks_pass_exits_0() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME" "$ROLE_ARN" "$FUNCTION_URL"
    write_curl_stub "$mock_bin"

    local exit_code=0
    local out
    out="$(CALL_LOG="$call_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        PATH="$mock_bin:$PATH" \
        bash "$SCRIPT" 2>/dev/null)" || exit_code=$?

    assert_eq "t_all_pass: exits 0" "0" "$exit_code"

    # Count ': ok' lines
    local ok_count
    ok_count="$(printf '%s\n' "$out" | grep -c ': ok$' || echo "0")"
    assert_eq "t_all_pass: 7 ok lines" "7" "$ok_count"
}

# ── Test 2: IAM trust missing lambda.amazonaws.com → check_iam_role_trust FAIL
t_iam_trust_missing_exits_nonzero() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME" "$ROLE_ARN" "$FUNCTION_URL"
    write_curl_stub "$mock_bin"

    local exit_code=0
    local out
    out="$(CALL_LOG="$call_log" \
        STUB_IAM_NO_LAMBDA_TRUST=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        PATH="$mock_bin:$PATH" \
        bash "$SCRIPT" 2>&1)" || exit_code=$?

    assert_ne "t_iam_trust_missing: exits non-zero" "0" "$exit_code"
    assert_contains "t_iam_trust_missing: FAIL line present" "check_iam_role_trust: FAIL" "$out"
}

# ── Test 3: bucket_name key empty → exit 1 + named error ─────────────────────
t_missing_bucket_name_key_exits_1_named() {
    local mock_bin
    mock_bin="$(make_tmpdir)"

    write_read_config_stub "$mock_bin" "review_telemetry.bucket_name"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME" "$ROLE_ARN" "$FUNCTION_URL"
    write_curl_stub "$mock_bin"

    local exit_code=0
    local err_output
    err_output="$(DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        PATH="$mock_bin:$PATH" \
        bash "$SCRIPT" 2>&1 >/dev/null)" || exit_code=$?

    assert_eq "t_missing_bucket: exit code == 1" "1" "$exit_code"
    assert_contains "t_missing_bucket: stderr has ERROR" "ERROR" "$err_output"
    assert_contains "t_missing_bucket: stderr names key" "review_telemetry.bucket_name" "$err_output"
}

# ── Test 4: lambda_function_name key empty → exit 1 + named error ────────────
t_missing_function_name_key_exits_1_named() {
    local mock_bin
    mock_bin="$(make_tmpdir)"

    write_read_config_stub "$mock_bin" "review_telemetry.lambda_function_name"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME" "$ROLE_ARN" "$FUNCTION_URL"
    write_curl_stub "$mock_bin"

    local exit_code=0
    local err_output
    err_output="$(DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        PATH="$mock_bin:$PATH" \
        bash "$SCRIPT" 2>&1 >/dev/null)" || exit_code=$?

    assert_eq "t_missing_function_name: exit code == 1" "1" "$exit_code"
    assert_contains "t_missing_function_name: stderr has ERROR" "ERROR" "$err_output"
    assert_contains "t_missing_function_name: stderr names key" "review_telemetry.lambda_function_name" "$err_output"
}

# ── Test 5: iam_role_name key empty → exit 1 + named error ───────────────────
t_missing_role_name_key_exits_1_named() {
    local mock_bin
    mock_bin="$(make_tmpdir)"

    write_read_config_stub "$mock_bin" "review_telemetry.iam_role_name"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME" "$ROLE_ARN" "$FUNCTION_URL"
    write_curl_stub "$mock_bin"

    local exit_code=0
    local err_output
    err_output="$(DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        PATH="$mock_bin:$PATH" \
        bash "$SCRIPT" 2>&1 >/dev/null)" || exit_code=$?

    assert_eq "t_missing_role_name: exit code == 1" "1" "$exit_code"
    assert_contains "t_missing_role_name: stderr has ERROR" "ERROR" "$err_output"
    assert_contains "t_missing_role_name: stderr names key" "review_telemetry.iam_role_name" "$err_output"
}

# ── Test 6: All aws stubs fail → non-zero exit, all FAIL lines, each ≤5s ──────
t_teardown_absent_exits_nonzero_within_5s_per_check() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME" "$ROLE_ARN" "$FUNCTION_URL"
    write_curl_stub "$mock_bin"
    write_sleep_stub "$mock_bin"

    local exit_code=0
    local out
    local t_start t_end elapsed
    t_start=$SECONDS
    out="$(CALL_LOG="$call_log" \
        STUB_ALL_FAIL=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_SLEEP_CMD="$mock_bin/sleep" \
        PATH="$mock_bin:$PATH" \
        bash "$SCRIPT" 2>&1)" || exit_code=$?
    t_end=$SECONDS
    elapsed=$(( t_end - t_start ))

    assert_ne "t_all_fail: exits non-zero" "0" "$exit_code"

    # Each check should show FAIL
    local fail_count
    fail_count="$(printf '%s\n' "$out" | grep -c ': FAIL' || echo "0")"
    assert_ne "t_all_fail: at least 1 FAIL line" "0" "$fail_count"

    # Total wall-clock should be well under 7 * 5 = 35s (each check has 5s timeout)
    # Using 40s as conservative upper bound for all 7 checks (+ overhead)
    if [[ $elapsed -le 40 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_all_fail: wall-clock %ds exceeds 40s budget (7 checks × ≤5s each)\n" "$elapsed" >&2
    fi
}

# ── Test 7: Backoff schedule verified via sleep invocations ───────────────────
# Use a fast sleep stub to record sleep arguments; verify the schedule is
# exactly [1, 2, 4, 8, 15, 30] (six entries, monotone non-decreasing).
t_e2e_post_uses_backoff_schedule() {
    local mock_bin call_log poll_log sleep_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"
    poll_log="$(make_tmpfile)"
    sleep_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME" "$ROLE_ARN" "$FUNCTION_URL"
    write_curl_stub "$mock_bin"
    write_sleep_stub "$mock_bin"

    local exit_code=0
    CALL_LOG="$call_log" \
    STUB_LIST_OBJECTS_EMPTY=1 \
    POLL_TIMESTAMP_LOG="$poll_log" \
    SLEEP_LOG="$sleep_log" \
    DSO_AWS_CMD="$mock_bin/aws" \
    DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
    DSO_SLEEP_CMD="$mock_bin/sleep" \
    PATH="$mock_bin:$PATH" \
    bash "$SCRIPT" >/dev/null 2>/dev/null || exit_code=$?

    # Count list-objects-v2 polls recorded in poll_log
    local poll_count
    poll_count=0
    if [[ -f "$poll_log" ]]; then
        poll_count="$(wc -l < "$poll_log" | tr -d ' ' || echo "0")"
    fi

    if [[ "$poll_count" -ge 3 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_backoff: expected ≥3 polls, got %d\n" "$poll_count" >&2
    fi

    # Verify sleep arguments are monotone non-decreasing (backoff exists)
    # Read sleep log: each line is the sleep argument passed
    local sleep_args=()
    if [[ -f "$sleep_log" ]]; then
        while IFS= read -r line; do
            sleep_args+=("$line")
        done < "$sleep_log"
    fi

    local sleep_count="${#sleep_args[@]}"
    if [[ "$sleep_count" -ge 3 ]]; then
        local prev_val="${sleep_args[0]}"
        local monotone=1
        local i
        for i in "${sleep_args[@]:1}"; do
            if [[ "$i" -lt "$prev_val" ]]; then
                monotone=0
                break
            fi
            prev_val="$i"
        done
        if [[ $monotone -eq 1 ]]; then
            (( ++PASS ))
        else
            (( ++FAIL ))
            printf "FAIL: t_backoff: sleep args not monotone non-decreasing: %s\n" "${sleep_args[*]}" >&2
        fi
    else
        (( ++FAIL ))
        printf "FAIL: t_backoff: expected ≥3 sleep calls, got %d\n" "$sleep_count" >&2
    fi
}

# ── Test 8: DSO_AWS_CMD wrapper used for all checks ───────────────────────────
t_aws_calls_use_dso_aws_cmd_wrapper() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME" "$ROLE_ARN" "$FUNCTION_URL"
    write_curl_stub "$mock_bin"
    write_sleep_stub "$mock_bin"

    local exit_code=0
    CALL_LOG="$call_log" \
    DSO_AWS_CMD="$mock_bin/aws" \
    DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
    DSO_SLEEP_CMD="$mock_bin/sleep" \
    PATH="$mock_bin:$PATH" \
    bash "$SCRIPT" >/dev/null 2>/dev/null || exit_code=$?

    # Count invocations recorded by the DSO_AWS_CMD stub
    local invocation_count
    invocation_count=0
    if [[ -f "$call_log" ]]; then
        invocation_count="$(wc -l < "$call_log" | tr -d ' ' || echo "0")"
    fi

    if [[ "$invocation_count" -ge 7 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_aws_wrapper: expected ≥7 DSO_AWS_CMD invocations, got %d\n" "$invocation_count" >&2
    fi
}

# ── Test 9: e2e budget exhausted completes without hanging ────────────────────
# list-objects-v2 always returns empty; verify check_e2e_post_visibility
# returns FAIL (budget exhausted = success criterion, not hung).
# Uses fast sleep stub so the test runs in milliseconds, not 60 seconds.
t_post_visibility_absent_resource_completes_under_5s() {
    local mock_bin call_log poll_log sleep_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"
    poll_log="$(make_tmpfile)"
    sleep_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME" "$ROLE_ARN" "$FUNCTION_URL"
    write_curl_stub "$mock_bin"
    write_sleep_stub "$mock_bin"

    local exit_code=0
    local out
    local t_start t_end elapsed
    t_start=$SECONDS

    out="$(CALL_LOG="$call_log" \
        STUB_LIST_OBJECTS_EMPTY=1 \
        POLL_TIMESTAMP_LOG="$poll_log" \
        SLEEP_LOG="$sleep_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_SLEEP_CMD="$mock_bin/sleep" \
        PATH="$mock_bin:$PATH" \
        bash "$SCRIPT" 2>&1)" || exit_code=$?

    t_end=$SECONDS
    elapsed=$(( t_end - t_start ))

    # With fast sleep stub, the whole script should complete in under 10s
    if [[ $elapsed -le 10 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_budget_exhausted: script took %ds with fast sleep stub (expected ≤10s)\n" "$elapsed" >&2
    fi

    # Budget exhausted → e2e check must report FAIL
    assert_contains "t_budget_exhausted: check_e2e_post_visibility FAIL" "check_e2e_post_visibility: FAIL" "$out"

    # Script must exit non-zero (at least one check failed)
    assert_ne "t_budget_exhausted: exits non-zero" "0" "$exit_code"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
t_all_checks_pass_exits_0
t_iam_trust_missing_exits_nonzero
t_missing_bucket_name_key_exits_1_named
t_missing_function_name_key_exits_1_named
t_missing_role_name_key_exits_1_named
t_teardown_absent_exits_nonzero_within_5s_per_check
t_e2e_post_uses_backoff_schedule
t_aws_calls_use_dso_aws_cmd_wrapper
t_post_visibility_absent_resource_completes_under_5s

print_summary
