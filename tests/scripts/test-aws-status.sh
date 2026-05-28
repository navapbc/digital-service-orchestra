#!/usr/bin/env bash
set -euo pipefail
# tests/scripts/test-aws-status.sh
# Behavioral tests for plugins/dso/scripts/telemetry/aws-status.sh
#
# All AWS calls are stubbed via DSO_AWS_CMD — never touches real AWS endpoints.
# Config reads are stubbed via DSO_READ_CONFIG_CMD.
#
# Cases covered:
#   1. t_all_present_schema_version_1        — happy path; exits 0; schema_version==1; all 5 keys present
#   2. t_lambda_absent_exits_0_present_false — lambda aws call fails; lambda.present==false; still exits 0
#   3. t_config_key_missing_exits_1          — read-config returns empty for bucket_name; exits 1 with ERROR on stderr
#   4. t_metrics_event_count_integer         — cloudwatch returns datapoint; last_24h_event_count is integer
#   5. t_all_absent_exits_0_structure        — all aws probes fail; exits 0; all 4 resources present==false; metrics.last_24h_event_count==0
#   6. t_log_group_name_derived_from_function_name — log group name equals /aws/lambda/<FUNCTION_NAME>
#
# Usage: bash tests/scripts/test-aws-status.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/telemetry/aws-status.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-aws-status.sh ==="

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
    d="$(mktemp -d "${TMPDIR:-/tmp}/aws-status-test.XXXXXX")"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

make_tmpfile() {
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/aws-status-test.XXXXXX")"
    _TEST_TMPDIRS+=("$f")
    echo "$f"
}

# ── Shared fixture constants ───────────────────────────────────────────────────
BUCKET_NAME="test-bucket"
FUNCTION_NAME="test-function"
ROLE_NAME="test-role"
LOG_GROUP_NAME="/aws/lambda/${FUNCTION_NAME}"

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
    *) echo "" ;;
esac
exit 0
STUBEOF
    chmod +x "$bin_dir/read-config-stub.sh"
}

# ── Helper: write happy-path aws stub ─────────────────────────────────────────
# Stub env vars (read at runtime):
#   CALL_LOG                — file path for logging each invocation
#   STUB_LAMBDA_ABSENT      — 1 → lambda get-function exits 1
#   STUB_ALL_ABSENT         — 1 → all resource probes fail (exit 1)
#   STUB_METRIC_COUNT       — integer returned as cloudwatch datapoint Sum (default 0)
write_aws_stub() {
    local bin_dir="$1"
    local bucket_name="$2"
    local function_name="$3"
    local role_name="$4"
    # shellcheck disable=SC2016
    cat > "$bin_dir/aws" << STUBEOF
#!/usr/bin/env bash
CALL_LOG="\${CALL_LOG:-/dev/null}"
STUB_LAMBDA_ABSENT="\${STUB_LAMBDA_ABSENT:-0}"
STUB_ALL_ABSENT="\${STUB_ALL_ABSENT:-0}"
STUB_METRIC_COUNT="\${STUB_METRIC_COUNT:-0}"

echo "\$*" >> "\$CALL_LOG"

sub="\${1:-}"
sub2="\${2:-}"

# ── All-absent mode ────────────────────────────────────────────────────────────
if [[ "\$STUB_ALL_ABSENT" == "1" ]]; then
    if [[ "\$sub" == "cloudwatch" ]]; then
        echo '{"Datapoints":[]}'
        exit 0
    fi
    exit 1
fi

# ── S3 ────────────────────────────────────────────────────────────────────────
if [[ "\$sub" == "s3api" && "\$sub2" == "head-bucket" ]]; then
    exit 0
fi

if [[ "\$sub" == "s3api" && "\$sub2" == "get-bucket-lifecycle-configuration" ]]; then
    echo '{"Rules":[{"Status":"Enabled","Transitions":[{"Days":90,"StorageClass":"GLACIER_IR"}]}]}'
    exit 0
fi

if [[ "\$sub" == "s3api" && "\$sub2" == "get-public-access-block" ]]; then
    echo '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}}'
    exit 0
fi

if [[ "\$sub" == "s3api" && "\$sub2" == "get-bucket-encryption" ]]; then
    echo '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}'
    exit 0
fi

# ── Lambda ────────────────────────────────────────────────────────────────────
if [[ "\$sub" == "lambda" && "\$sub2" == "get-function" ]]; then
    if [[ "\$STUB_LAMBDA_ABSENT" == "1" ]]; then exit 1; fi
    echo '{"Configuration":{"FunctionName":"$function_name","FunctionArn":"arn:aws:lambda:us-east-1:123456789012:function:$function_name"}}'
    exit 0
fi

if [[ "\$sub" == "lambda" && "\$sub2" == "get-function-url-config" ]]; then
    if [[ "\$STUB_LAMBDA_ABSENT" == "1" ]]; then exit 1; fi
    echo '{"FunctionUrl":"https://abc123.lambda-url.us-east-1.on.aws/"}'
    exit 0
fi

if [[ "\$sub" == "lambda" && "\$sub2" == "get-function-concurrency" ]]; then
    if [[ "\$STUB_LAMBDA_ABSENT" == "1" ]]; then exit 1; fi
    echo '{"ReservedConcurrentExecutions":10}'
    exit 0
fi

# ── IAM ───────────────────────────────────────────────────────────────────────
if [[ "\$sub" == "iam" && "\$sub2" == "get-role" ]]; then
    echo '{"Role":{"RoleName":"$role_name","AssumeRolePolicyDocument":{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}}}'
    exit 0
fi

# ── CloudWatch Logs ───────────────────────────────────────────────────────────
if [[ "\$sub" == "logs" && "\$sub2" == "describe-log-groups" ]]; then
    echo '{"logGroups":[{"logGroupName":"/aws/lambda/$function_name","retentionInDays":7}]}'
    exit 0
fi

# ── CloudWatch Metrics ────────────────────────────────────────────────────────
if [[ "\$sub" == "cloudwatch" && "\$sub2" == "get-metric-statistics" ]]; then
    count="\$STUB_METRIC_COUNT"
    if [[ "\$count" -gt 0 ]]; then
        echo "{\"Datapoints\":[{\"Sum\":\$count,\"Unit\":\"Count\"}]}"
    else
        echo '{"Datapoints":[]}'
    fi
    exit 0
fi

# Default: succeed silently
exit 0
STUBEOF
    chmod +x "$bin_dir/aws"
}

# ── Test 1: Happy path — exits 0, schema_version==1, all 5 top-level keys ─────
t_all_present_schema_version_1() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME"

    local exit_code=0
    local out
    out="$(CALL_LOG="$call_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" 2>/dev/null)" || exit_code=$?

    assert_eq "t_all_present: exits 0" "0" "$exit_code"

    local schema_version
    schema_version="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('schema_version',''))" 2>/dev/null || echo "")"
    assert_eq "t_all_present: schema_version==1" "1" "$schema_version"

    for key in bucket lambda iam_role log_group metrics; do
        local has_key
        has_key="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if '$key' in d else 'no')" 2>/dev/null || echo "no")"
        assert_eq "t_all_present: has key '$key'" "yes" "$has_key"
    done

    # bucket.present==true
    local bucket_present
    bucket_present="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('bucket',{}).get('present') is True else 'false')" 2>/dev/null || echo "false")"
    assert_eq "t_all_present: bucket.present==true" "true" "$bucket_present"
}

# ── Test 2: Lambda absent → exits 0, lambda.present==false ────────────────────
t_lambda_absent_exits_0_present_false() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME"

    local exit_code=0
    local out
    out="$(CALL_LOG="$call_log" \
        STUB_LAMBDA_ABSENT=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" 2>/dev/null)" || exit_code=$?

    assert_eq "t_lambda_absent: exits 0" "0" "$exit_code"

    local lambda_present
    lambda_present="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print('false' if d.get('lambda',{}).get('present') is False else 'true')" 2>/dev/null || echo "true")"
    assert_eq "t_lambda_absent: lambda.present==false" "false" "$lambda_present"

    # Other resources should still be present
    local bucket_present
    bucket_present="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('bucket',{}).get('present') is True else 'false')" 2>/dev/null || echo "false")"
    assert_eq "t_lambda_absent: bucket still present==true" "true" "$bucket_present"
}

# ── Test 3: Config key missing → exits 1 with ERROR on stderr ─────────────────
t_config_key_missing_exits_1() {
    local mock_bin
    mock_bin="$(make_tmpdir)"

    # Make bucket_name missing
    write_read_config_stub "$mock_bin" "review_telemetry.bucket_name"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME"

    local exit_code=0
    local err_output
    err_output="$(DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" 2>&1 >/dev/null)" || exit_code=$?

    assert_ne "t_config_missing: exits non-zero" "0" "$exit_code"
    assert_contains "t_config_missing: stderr contains ERROR" "ERROR" "$err_output"
}

# ── Test 4: CloudWatch returns datapoint → last_24h_event_count is integer ────
t_metrics_event_count_integer() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME"

    local out
    out="$(CALL_LOG="$call_log" \
        STUB_METRIC_COUNT=42 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" 2>/dev/null)" || true

    local event_count
    event_count="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('metrics',{}).get('last_24h_event_count','missing'))" 2>/dev/null || echo "missing")"
    assert_eq "t_metrics: last_24h_event_count==42" "42" "$event_count"

    # Verify it's an integer (not a string) in the JSON
    local is_int
    is_int="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if isinstance(d.get('metrics',{}).get('last_24h_event_count'), int) else 'no')" 2>/dev/null || echo "no")"
    assert_eq "t_metrics: event_count is JSON integer type" "yes" "$is_int"
}

# ── Test 5: All resources absent → exits 0, all present==false, metrics count 0
t_all_absent_exits_0_structure() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$FUNCTION_NAME" "$ROLE_NAME"

    local exit_code=0
    local out
    out="$(CALL_LOG="$call_log" \
        STUB_ALL_ABSENT=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" 2>/dev/null)" || exit_code=$?

    assert_eq "t_all_absent: exits 0" "0" "$exit_code"

    for resource in bucket lambda iam_role log_group; do
        local present_val
        present_val="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print('false' if d.get('$resource',{}).get('present') is False else 'true')" 2>/dev/null || echo "true")"
        assert_eq "t_all_absent: $resource.present==false" "false" "$present_val"
    done

    local event_count
    event_count="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('metrics',{}).get('last_24h_event_count','missing'))" 2>/dev/null || echo "missing")"
    assert_eq "t_all_absent: last_24h_event_count==0" "0" "$event_count"

    # metrics key always present
    local has_metrics
    has_metrics="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'metrics' in d else 'no')" 2>/dev/null || echo "no")"
    assert_eq "t_all_absent: metrics key always present" "yes" "$has_metrics"
}

# ── Test 6: Log group name derived from function name (not a separate config) ─
t_log_group_name_derived_from_function_name() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    # Use a custom function name to verify derivation
    local custom_fn="my-custom-function"
    # Override the read-config stub for a custom function name
    cat > "$mock_bin/read-config-stub.sh" << STUBEOF
#!/usr/bin/env bash
key="\${1:-}"
case "\$key" in
    review_telemetry.bucket_name)          echo "$BUCKET_NAME" ;;
    review_telemetry.lambda_function_name) echo "$custom_fn" ;;
    review_telemetry.iam_role_name)        echo "$ROLE_NAME" ;;
    *) echo "" ;;
esac
exit 0
STUBEOF
    chmod +x "$mock_bin/read-config-stub.sh"

    write_aws_stub "$mock_bin" "$BUCKET_NAME" "$custom_fn" "$ROLE_NAME"

    local out
    out="$(CALL_LOG="$call_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" 2>/dev/null)" || true

    # log_group.name should be /aws/lambda/<custom_fn>
    local lg_name
    lg_name="$(printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('log_group',{}).get('name',''))" 2>/dev/null || echo "")"
    assert_eq "t_log_group_derived: name==/aws/lambda/$custom_fn" "/aws/lambda/$custom_fn" "$lg_name"

    # Confirm that describe-log-groups was called with the derived name in the call log
    local log_group_call_correct=0
    if grep "logs describe-log-groups" "$call_log" 2>/dev/null | grep -q "/aws/lambda/${custom_fn}"; then
        log_group_call_correct=1
    fi
    assert_eq "t_log_group_derived: describe-log-groups used derived name" "1" "$log_group_call_correct"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
t_all_present_schema_version_1
t_lambda_absent_exits_0_present_false
t_config_key_missing_exits_1
t_metrics_event_count_integer
t_all_absent_exits_0_structure
t_log_group_name_derived_from_function_name

print_summary
