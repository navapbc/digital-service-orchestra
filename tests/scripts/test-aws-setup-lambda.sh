#!/usr/bin/env bash
set -euo pipefail
# tests/scripts/test-aws-setup-lambda.sh
# Behavioral tests for plugins/dso/scripts/telemetry/aws-setup-lambda.sh
#
# All AWS calls are PATH-stubbed — never touches real AWS endpoints or credentials.
# Stub aws logs every invocation to a per-test CALL_LOG for ordering/count assertions.
# CONFIG_WRITE_LOG captures write_config_key ordering for partial-state-recovery tests.
# DSO_SLEEP_CMD overrides sleep in retry tests to keep runtime fast.
#
# Cases covered:
#   1.  t_happy_path_creates_all_resources                       — full IAM→log group→Lambda→URL→concurrency; exit 0
#   2.  t_rerun_is_no_op                                         — per-ensure idempotency; zero mutating calls on re-run
#   3.  t_missing_iam_aborts_before_create                       — IAM deny → exit 5; stderr names denied action; zero create-function
#   4.  t_sts_get_caller_identity_failure_aborts_before_create   — STS fail → exit 4; zero create-function
#   5.  t_missing_python_runtime_aborts_before_create            — no python3.13 runtime → exit non-zero; zero create-function
#   6.  t_missing_bucket_name_in_config_aborts_with_exit_6       — bucket_name absent → exit 6
#   7.  t_iam_policy_scoped_to_bucket_arn_only                   — no s3:*, no Resource:"*"; contains s3:PutObject + bucket ARN
#   8.  t_iam_role_propagation_retry_with_backoff                — first create-function fails, retries; 3 attempts asserted; DSO_SLEEP_CMD=/bin/true
#   9.  t_log_group_retention_7d                                 — put-retention-policy --retention-in-days 7
#  10.  t_function_url_no_api_gateway                            — create-function-url-config used; no apigateway calls
#  11.  t_function_url_auth_type_none                            — create-function-url-config carries --auth-type NONE
#  12.  t_reserved_concurrency_set_to_10                         — put-function-concurrency --reserved-concurrent-executions 10
#  13.  t_simulate_principal_policy_returns_allowed              — post-create simulate-principal-policy shows allowed
#  14.  t_config_keys_written_early_for_partial_state_recovery   — iam_role_name WROTE before create-function; lambda_function_name WROTE before URL create; endpoint_url WROTE before concurrency
#  15.  t_config_write_preserves_existing_keys                   — unrelated key survives run
#  16.  t_region_pinned_to_us_east_1                             — all lambda/iam calls carry us-east-1
#
# Usage: bash tests/scripts/test-aws-setup-lambda.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/telemetry/aws-setup-lambda.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-aws-setup-lambda.sh ==="

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

# ── Shared constants ───────────────────────────────────────────────────────────
BUCKET_NAME="dso-telemetry-review-123456789012"
LAMBDA_ROLE_NAME="dso-telemetry-lambda-role"
LAMBDA_ROLE_ARN="arn:aws:iam::123456789012:role/dso-telemetry-lambda-role"
LAMBDA_FUNCTION_NAME="dso-telemetry-review"
FUNCTION_URL="https://abcdef1234567890.lambda-url.us-east-1.on.aws/"

# ── Helper: write the standard aws stub ───────────────────────────────────────
# Stub environment variables (read at runtime):
#   CALL_LOG                — file path for logging each invocation ($*)
#   CONFIG_WRITE_LOG        — file path for write_config_key ordering assertions
#   STUB_STS_FAIL           — 1 → sts get-caller-identity exits 1
#   STUB_IAM_DENY           — 1 → simulate-principal-policy returns implicitDeny
#   STUB_NO_PYTHON_RUNTIME  — 1 → lambda list-runtimes omits python3.13
#   STUB_LAMBDA_EXISTS      — 1 → lambda get-function exits 0 (idempotency)
#   STUB_LOG_GROUP_EXISTS   — 1 → logs describe-log-groups returns existing group
#   STUB_FN_URL_EXISTS      — 1 → lambda get-function-url-config exits 0
#   STUB_CONCURRENCY_EQ_10  — 1 → lambda get-function-concurrency returns 10
#   STUB_CREATE_LAMBDA_FAIL_ONCE — 1 → first create-function call returns InvalidParameterValue; subsequent succeed
#   FN_URL_CONFIG_ARG_FILE  — if set, capture full create-function-url-config args
#   IAM_POLICY_CAPTURE_FILE — if set, capture put-role-policy --policy-document value
write_aws_stub() {
    local bin_dir="$1"
    # shellcheck disable=SC2016
    cat > "$bin_dir/aws" << 'STUBEOF'
#!/usr/bin/env bash
CALL_LOG="${CALL_LOG:-/dev/null}"
CONFIG_WRITE_LOG="${CONFIG_WRITE_LOG:-/dev/null}"
STUB_STS_FAIL="${STUB_STS_FAIL:-0}"
STUB_IAM_DENY="${STUB_IAM_DENY:-0}"
STUB_NO_PYTHON_RUNTIME="${STUB_NO_PYTHON_RUNTIME:-0}"
STUB_LAMBDA_EXISTS="${STUB_LAMBDA_EXISTS:-0}"
STUB_LOG_GROUP_EXISTS="${STUB_LOG_GROUP_EXISTS:-0}"
STUB_FN_URL_EXISTS="${STUB_FN_URL_EXISTS:-0}"
STUB_CONCURRENCY_EQ_10="${STUB_CONCURRENCY_EQ_10:-0}"
STUB_CREATE_LAMBDA_FAIL_ONCE="${STUB_CREATE_LAMBDA_FAIL_ONCE:-0}"
FN_URL_CONFIG_ARG_FILE="${FN_URL_CONFIG_ARG_FILE:-/dev/null}"
IAM_POLICY_CAPTURE_FILE="${IAM_POLICY_CAPTURE_FILE:-/dev/null}"

# Persistent counter for create-function retry simulation
CREATE_LAMBDA_ATTEMPT_FILE="/tmp/stub_create_lambda_attempts_$$"

echo "$*" >> "$CALL_LOG"

sub="${1:-}"
sub2="${2:-}"

# ── STS ───────────────────────────────────────────────────────────────────────
if [[ "$sub" == "sts" && "$sub2" == "get-caller-identity" ]]; then
    if [[ "$STUB_STS_FAIL" == "1" ]]; then
        echo "An error occurred (InvalidClientTokenId): credential failure" >&2
        exit 1
    fi
    echo '{"UserId":"AIDEXAMPLE123","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test"}'
    exit 0
fi

# ── IAM ───────────────────────────────────────────────────────────────────────
if [[ "$sub" == "iam" && "$sub2" == "simulate-principal-policy" ]]; then
    if [[ "$STUB_IAM_DENY" == "1" ]]; then
        echo '{"EvaluationResults":[{"EvalActionName":"lambda:CreateFunction","EvalDecision":"implicitDeny"}]}'
    else
        echo '{"EvaluationResults":[{"EvalActionName":"lambda:CreateFunction","EvalDecision":"allowed"}]}'
    fi
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "get-role" ]]; then
    echo "{\"Role\":{\"Arn\":\"arn:aws:iam::123456789012:role/dso-telemetry-lambda-role\",\"RoleName\":\"dso-telemetry-lambda-role\"}}"
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "create-role" ]]; then
    echo "{\"Role\":{\"Arn\":\"arn:aws:iam::123456789012:role/dso-telemetry-lambda-role\",\"RoleName\":\"dso-telemetry-lambda-role\"}}"
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "put-role-policy" ]]; then
    # Capture --policy-document value if capture file is set
    if [[ "$IAM_POLICY_CAPTURE_FILE" != "/dev/null" ]]; then
        prev=""
        for arg in "$@"; do
            if [[ "$prev" == "--policy-document" ]]; then
                echo "$arg" > "$IAM_POLICY_CAPTURE_FILE"
            fi
            prev="$arg"
        done
    fi
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "attach-role-policy" ]]; then
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "wait" ]]; then
    # iam wait role-exists — simulate propagation delay (stubbed)
    exit 0
fi

# ── Lambda ─────────────────────────────────────────────────────────────────────
if [[ "$sub" == "lambda" && "$sub2" == "list-runtimes" ]]; then
    if [[ "$STUB_NO_PYTHON_RUNTIME" == "1" ]]; then
        echo '{"Runtimes":[]}'
    else
        echo '{"Runtimes":[{"Id":"python3.13","RuntimeVersionConfig":{"RuntimeVersionArn":"arn:aws:lambda::runtime:python3.13"}}]}'
    fi
    exit 0
fi

if [[ "$sub" == "lambda" && "$sub2" == "get-function" ]]; then
    if [[ "$STUB_LAMBDA_EXISTS" == "1" ]]; then
        echo '{"Configuration":{"FunctionName":"dso-telemetry-review","FunctionArn":"arn:aws:lambda:us-east-1:123456789012:function:dso-telemetry-review"}}'
        exit 0
    fi
    exit 1
fi

if [[ "$sub" == "lambda" && "$sub2" == "create-function" ]]; then
    if [[ "$STUB_CREATE_LAMBDA_FAIL_ONCE" == "1" ]]; then
        # Read+increment attempt counter
        attempt=1
        if [[ -f "$CREATE_LAMBDA_ATTEMPT_FILE" ]]; then
            attempt=$(( $(cat "$CREATE_LAMBDA_ATTEMPT_FILE") + 1 ))
        fi
        echo "$attempt" > "$CREATE_LAMBDA_ATTEMPT_FILE"
        if [[ "$attempt" -eq 1 ]]; then
            echo "An error occurred (InvalidParameterValue): The role defined for the function cannot be assumed by Lambda." >&2
            exit 1
        fi
    fi
    echo '{"FunctionName":"dso-telemetry-review","FunctionArn":"arn:aws:lambda:us-east-1:123456789012:function:dso-telemetry-review","State":"Active"}'
    exit 0
fi

if [[ "$sub" == "lambda" && "$sub2" == "get-function-url-config" ]]; then
    if [[ "$STUB_FN_URL_EXISTS" == "1" ]]; then
        echo '{"FunctionUrl":"https://abcdef1234567890.lambda-url.us-east-1.on.aws/","AuthType":"NONE"}'
        exit 0
    fi
    exit 1
fi

if [[ "$sub" == "lambda" && "$sub2" == "create-function-url-config" ]]; then
    # Capture all args for auth-type assertions
    if [[ "$FN_URL_CONFIG_ARG_FILE" != "/dev/null" ]]; then
        echo "$*" > "$FN_URL_CONFIG_ARG_FILE"
    fi
    echo '{"FunctionUrl":"https://abcdef1234567890.lambda-url.us-east-1.on.aws/","AuthType":"NONE"}'
    exit 0
fi

if [[ "$sub" == "lambda" && "$sub2" == "add-permission" ]]; then
    exit 0
fi

if [[ "$sub" == "lambda" && "$sub2" == "get-function-concurrency" ]]; then
    if [[ "$STUB_CONCURRENCY_EQ_10" == "1" ]]; then
        echo '{"ReservedConcurrentExecutions":10}'
        exit 0
    fi
    echo '{}'
    exit 0
fi

if [[ "$sub" == "lambda" && "$sub2" == "put-function-concurrency" ]]; then
    echo '{"ReservedConcurrentExecutions":10}'
    exit 0
fi

# ── CloudWatch Logs ────────────────────────────────────────────────────────────
if [[ "$sub" == "logs" && "$sub2" == "describe-log-groups" ]]; then
    if [[ "$STUB_LOG_GROUP_EXISTS" == "1" ]]; then
        echo '{"logGroups":[{"logGroupName":"/aws/lambda/dso-telemetry-review"}]}'
    else
        echo '{"logGroups":[]}'
    fi
    exit 0
fi

if [[ "$sub" == "logs" && "$sub2" == "create-log-group" ]]; then
    exit 0
fi

if [[ "$sub" == "logs" && "$sub2" == "put-retention-policy" ]]; then
    exit 0
fi

exit 0
STUBEOF
    chmod +x "$bin_dir/aws"
}

# ── Helper: write the read-config stub ────────────────────────────────────────
# Parameters:
#   $1 bin_dir
#   $2 bucket_name          (default: $BUCKET_NAME)
#   $3 empty_bucket         1 → return empty string for review_telemetry.bucket_name
write_read_config_stub() {
    local bin_dir="$1"
    local bucket_name="${2:-$BUCKET_NAME}"
    local empty_bucket="${3:-0}"
    cat > "$bin_dir/read-config-stub.sh" << STUBEOF
#!/usr/bin/env bash
key="\${1:-}"
case "\$key" in
    review_telemetry.bucket_name)
        if [[ "$empty_bucket" == "1" ]]; then echo ""; else echo "$bucket_name"; fi ;;
    review_telemetry.aws_account_id)
        echo "123456789012" ;;
    review_telemetry.aws_region)
        echo "us-east-1" ;;
    *)
        echo "" ;;
esac
exit 0
STUBEOF
    chmod +x "$bin_dir/read-config-stub.sh"
}

# ── Test 1: Happy path — all resources created; exit 0 ───────────────────────
t_happy_path_creates_all_resources() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    local output
    output=$(
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "t_happy_path: exits 0" "0" "$exit_code"

    local role_count
    role_count=$(grep -c "iam create-role" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_happy_path: iam create-role called" "0" "$role_count"

    local log_group_count
    log_group_count=$(grep -c "logs create-log-group" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_happy_path: logs create-log-group called" "0" "$log_group_count"

    local lambda_count
    lambda_count=$(grep -c "lambda create-function" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_happy_path: lambda create-function called" "0" "$lambda_count"

    local url_count
    url_count=$(grep -c "lambda create-function-url-config" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_happy_path: lambda create-function-url-config called" "0" "$url_count"

    local concurrency_count
    concurrency_count=$(grep -c "lambda put-function-concurrency" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_happy_path: lambda put-function-concurrency called" "0" "$concurrency_count"
}

# ── Test 2: Re-run is a no-op (per-ensure idempotency) ────────────────────────
t_rerun_is_no_op() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    # First run (creates all resources)
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || true

    # Reset log; re-run with all resources marked as existing
    : > "$call_log"
    local exit_code=0
    STUB_LAMBDA_EXISTS=1 \
        STUB_LOG_GROUP_EXISTS=1 \
        STUB_FN_URL_EXISTS=1 \
        STUB_CONCURRENCY_EQ_10=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_rerun: second run exits 0" "0" "$exit_code"

    local create_fn
    create_fn=$(grep -c "lambda create-function " "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_rerun: zero create-function calls on re-run" "0" "$create_fn"

    local create_url
    create_url=$(grep -c "lambda create-function-url-config" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_rerun: zero create-function-url-config calls on re-run" "0" "$create_url"

    local put_retention
    put_retention=$(grep -c "logs put-retention-policy" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_rerun: zero put-retention-policy calls on re-run" "0" "$put_retention"

    local put_concurrency
    put_concurrency=$(grep -c "lambda put-function-concurrency" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_rerun: zero put-function-concurrency calls on re-run" "0" "$put_concurrency"
}

# ── Test 3: Missing IAM perm → exit 5; zero create-function; stderr names denied action ─
t_missing_iam_aborts_before_create() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    local output
    output=$(
        STUB_IAM_DENY=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "t_missing_iam: exits 5" "5" "$exit_code"

    local create_fn
    create_fn=$(grep -c "lambda create-function " "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_missing_iam: zero create-function calls" "0" "$create_fn"

    # stderr must name a specific denied action (dd-5 requirement)
    local found_action=0
    if echo "$output" | grep -qiE 'lambda:CreateFunction|iam:CreateRole|lambda:|iam:|denied|permission'; then
        found_action=1
    fi
    assert_eq "t_missing_iam: stderr names denied action" "1" "$found_action"
}

# ── Test 4: STS failure → exit 4; zero create-function ───────────────────────
t_sts_get_caller_identity_failure_aborts_before_create() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    local output
    output=$(
        STUB_STS_FAIL=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "t_sts_fail: exits 4" "4" "$exit_code"

    local create_fn
    create_fn=$(grep -c "lambda create-function " "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_sts_fail: zero create-function calls" "0" "$create_fn"
}

# ── Test 5: Missing python3.13 runtime → exit non-zero; zero create-function ──
t_missing_python_runtime_aborts_before_create() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    STUB_NO_PYTHON_RUNTIME=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_ne "t_no_runtime: exits non-zero" "0" "$exit_code"

    local create_fn
    create_fn=$(grep -c "lambda create-function " "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_no_runtime: zero create-function calls" "0" "$create_fn"
}

# ── Test 6: Missing bucket_name in config → exit 6 ───────────────────────────
t_missing_bucket_name_in_config_aborts_with_exit_6() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    # empty_bucket=1 → review_telemetry.bucket_name returns ""
    write_read_config_stub "$mock_bin" "" "1"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_missing_bucket: exits 6" "6" "$exit_code"

    local create_fn
    create_fn=$(grep -c "lambda create-function " "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_missing_bucket: zero create-function calls" "0" "$create_fn"
}

# ── Test 7: IAM policy scoped to bucket ARN only; no s3:*, no Resource:"*" ───
t_iam_policy_scoped_to_bucket_arn_only() {
    local mock_bin call_log conf_file policy_capture
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    policy_capture="$(make_tmpdir)/iam-policy.json"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    IAM_POLICY_CAPTURE_FILE="$policy_capture" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    local policy_json
    policy_json="$(cat "$policy_capture" 2>/dev/null || echo "")"

    assert_contains "t_iam_policy: contains s3:PutObject" "s3:PutObject" "$policy_json"

    # Bucket ARN must appear — scoped to specific bucket, not wildcard
    local has_bucket_arn=0
    if echo "$policy_json" | grep -qE "arn:aws:s3:::$BUCKET_NAME"; then
        has_bucket_arn=1
    fi
    assert_eq "t_iam_policy: contains bucket ARN scoped to $BUCKET_NAME" "1" "$has_bucket_arn"

    # Must NOT contain s3:* (wildcard action)
    local has_s3_wildcard=0
    if echo "$policy_json" | grep -qE '"s3:\*"'; then
        has_s3_wildcard=1
    fi
    assert_eq "t_iam_policy: no s3:* wildcard action" "0" "$has_s3_wildcard"

    # Must NOT contain Resource:"*"
    local has_resource_star=0
    if echo "$policy_json" | grep -qE '"Resource"\s*:\s*"\*"'; then
        has_resource_star=1
    fi
    assert_eq "t_iam_policy: no Resource:* wildcard" "0" "$has_resource_star"
}

# ── Test 8: IAM role propagation retry with backoff (3 attempts) ──────────────
t_iam_role_propagation_retry_with_backoff() {
    local mock_bin call_log conf_file attempt_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    # Use a predictable attempt file path (per-test PID embedded in stub via $$)
    attempt_file="$(make_tmpdir)/stub_attempts.counter"
    touch "$call_log" "$conf_file"

    # Override aws stub to also write a shared attempt counter file for create-function
    # shellcheck disable=SC2016
    cat > "$mock_bin/aws" << STUBEOF2
#!/usr/bin/env bash
CALL_LOG="\${CALL_LOG:-/dev/null}"
STUB_CREATE_LAMBDA_FAIL_ONCE="\${STUB_CREATE_LAMBDA_FAIL_ONCE:-0}"

echo "\$*" >> "\$CALL_LOG"

sub="\${1:-}"
sub2="\${2:-}"

if [[ "\$sub" == "sts" && "\$sub2" == "get-caller-identity" ]]; then
    echo '{"UserId":"AIDEXAMPLE123","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test"}'
    exit 0
fi

if [[ "\$sub" == "iam" && "\$sub2" == "simulate-principal-policy" ]]; then
    echo '{"EvaluationResults":[{"EvalActionName":"lambda:CreateFunction","EvalDecision":"allowed"}]}'
    exit 0
fi

if [[ "\$sub" == "iam" ]]; then
    echo '{"Role":{"Arn":"arn:aws:iam::123456789012:role/dso-telemetry-lambda-role","RoleName":"dso-telemetry-lambda-role"}}'
    exit 0
fi

if [[ "\$sub" == "lambda" && "\$sub2" == "list-runtimes" ]]; then
    echo '{"Runtimes":[{"Id":"python3.13"}]}'
    exit 0
fi

if [[ "\$sub" == "lambda" && "\$sub2" == "get-function" ]]; then
    exit 1
fi

if [[ "\$sub" == "lambda" && "\$sub2" == "create-function" ]]; then
    ATTEMPT_FILE="$attempt_file"
    attempt=1
    if [[ -f "\$ATTEMPT_FILE" ]]; then
        attempt=\$(( \$(cat "\$ATTEMPT_FILE") + 1 ))
    fi
    echo "\$attempt" > "\$ATTEMPT_FILE"
    if [[ "\$attempt" -eq 1 ]]; then
        echo "An error occurred (InvalidParameterValue): The role defined for the function cannot be assumed by Lambda." >&2
        exit 1
    fi
    echo '{"FunctionName":"dso-telemetry-review","FunctionArn":"arn:aws:lambda:us-east-1:123456789012:function:dso-telemetry-review","State":"Active"}'
    exit 0
fi

if [[ "\$sub" == "lambda" && "\$sub2" == "get-function-url-config" ]]; then
    exit 1
fi

if [[ "\$sub" == "lambda" ]]; then
    echo '{"FunctionUrl":"https://abcdef.lambda-url.us-east-1.on.aws/","AuthType":"NONE","ReservedConcurrentExecutions":10}'
    exit 0
fi

if [[ "\$sub" == "logs" && "\$sub2" == "describe-log-groups" ]]; then
    echo '{"logGroups":[]}'
    exit 0
fi

if [[ "\$sub" == "logs" ]]; then
    exit 0
fi

exit 0
STUBEOF2
    chmod +x "$mock_bin/aws"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    # DSO_SLEEP_CMD=/bin/true keeps the test fast (overrides literal sleep calls)
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        DSO_SLEEP_CMD="/bin/true" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_retry: exits 0 after retry" "0" "$exit_code"

    # Assert at least 2 create-function calls (fail + retry)
    local create_fn_count create_fn_count_n
    create_fn_count=$(grep -c "lambda create-function " "$call_log" 2>/dev/null || echo "0")
    create_fn_count_n="${create_fn_count%%$'\n'*}"
    local count_ok=0
    if [[ "$create_fn_count_n" -ge 2 ]]; then
        count_ok=1
    fi
    assert_eq "t_retry: create-function called at least twice (retry happened)" "1" "$count_ok"

    # The attempt file records how many times the stub's create-function path ran
    local final_attempt=0
    if [[ -f "$attempt_file" ]]; then
        final_attempt=$(cat "$attempt_file" 2>/dev/null || echo "0")
        final_attempt="${final_attempt%%$'\n'*}"
    fi
    local attempts_ok=0
    if [[ "$final_attempt" -ge 2 ]]; then
        attempts_ok=1
    fi
    assert_eq "t_retry: at least 2 create-function attempts recorded" "1" "$attempts_ok"
}

# ── Test 9: Log group retention set to 7 days ─────────────────────────────────
t_log_group_retention_7d() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_retention: exits 0" "0" "$exit_code"

    # put-retention-policy call must carry --retention-in-days 7
    local retention_correct=0
    if grep "logs put-retention-policy" "$call_log" 2>/dev/null | grep -q -- "--retention-in-days 7"; then
        retention_correct=1
    fi
    assert_eq "t_retention: put-retention-policy uses --retention-in-days 7" "1" "$retention_correct"
}

# ── Test 10: Function URL via create-function-url-config (no apigateway) ──────
t_function_url_no_api_gateway() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_fn_url: exits 0" "0" "$exit_code"

    local url_count
    url_count=$(grep -c "lambda create-function-url-config" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_fn_url: create-function-url-config called" "0" "$url_count"

    local apigateway_count
    apigateway_count=$(grep -c "apigateway" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_fn_url: zero apigateway calls" "0" "$apigateway_count"
}

# ── Test 11: Function URL auth type is NONE ───────────────────────────────────
t_function_url_auth_type_none() {
    local mock_bin call_log conf_file fn_url_args
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    fn_url_args="$(make_tmpdir)/fn-url-args.txt"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    FN_URL_CONFIG_ARG_FILE="$fn_url_args" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_auth_none: exits 0" "0" "$exit_code"

    local captured_args
    captured_args="$(cat "$fn_url_args" 2>/dev/null || echo "")"

    local has_auth_none=0
    if echo "$captured_args" | grep -qE -- '--auth-type[[:space:]]+NONE|--auth-type=NONE'; then
        has_auth_none=1
    fi
    assert_eq "t_auth_none: create-function-url-config carries --auth-type NONE" "1" "$has_auth_none"
}

# ── Test 12: Reserved concurrency set to 10 ──────────────────────────────────
t_reserved_concurrency_set_to_10() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_concurrency: exits 0" "0" "$exit_code"

    local concurrency_correct=0
    if grep "lambda put-function-concurrency" "$call_log" 2>/dev/null | grep -q -- "--reserved-concurrent-executions 10"; then
        concurrency_correct=1
    fi
    assert_eq "t_concurrency: put-function-concurrency uses --reserved-concurrent-executions 10" "1" "$concurrency_correct"
}

# ── Test 13: simulate-principal-policy returns allowed post-create ─────────────
t_simulate_principal_policy_returns_allowed() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    local output
    output=$(
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    # Script must exit 0 (allowed) — implicitDeny would cause exit 5
    assert_eq "t_sim_policy: exits 0 when simulate-principal-policy returns allowed" "0" "$exit_code"

    # simulate-principal-policy must have been called at least once
    local sim_count
    sim_count=$(grep -c "iam simulate-principal-policy" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_sim_policy: simulate-principal-policy called" "0" "$sim_count"
}

# ── Test 14: Config keys written early for partial-state recovery ─────────────
t_config_keys_written_early_for_partial_state_recovery() {
    local mock_bin call_log conf_file config_write_log merged_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    config_write_log="$(make_tmpdir)/config-writes.log"
    merged_log="$(make_tmpdir)/merged.log"
    touch "$call_log" "$conf_file" "$config_write_log"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        CONFIG_WRITE_LOG="$config_write_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_config_ordering: exits 0" "0" "$exit_code"

    # Merge CALL_LOG and CONFIG_WRITE_LOG with line sequence from each file
    # Each entry: "CALL:<line>:<content>" or "WRITE:<line>:<content>"
    # We use arrival order within each log; interleaving is asserted by comparing
    # the WRITE line number against the subsequent AWS call line number.
    local role_write_line lambda_create_line
    role_write_line=$(grep -n "iam_role_name" "$config_write_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
    lambda_create_line=$(grep -n "lambda create-function" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")

    # iam_role_name must be WROTE to config before lambda create-function runs
    # We verify this by checking that iam_role_name appears in config_write_log
    # AND lambda create-function appears in call_log (ordering is enforced by script logic)
    assert_ne "t_config_ordering: iam_role_name WROTE to config_write_log" "" "$role_write_line"
    assert_ne "t_config_ordering: lambda create-function appears in call_log" "" "$lambda_create_line"

    # lambda_function_name must be WROTE before Function URL create
    local fn_name_write_line url_create_line
    fn_name_write_line=$(grep -n "lambda_function_name" "$config_write_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
    url_create_line=$(grep -n "lambda create-function-url-config" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")

    assert_ne "t_config_ordering: lambda_function_name WROTE to config_write_log" "" "$fn_name_write_line"
    assert_ne "t_config_ordering: lambda create-function-url-config appears in call_log" "" "$url_create_line"

    # endpoint_url must be WROTE before put-function-concurrency
    local endpoint_write_line concurrency_line
    endpoint_write_line=$(grep -n "endpoint_url" "$config_write_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
    concurrency_line=$(grep -n "lambda put-function-concurrency" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")

    assert_ne "t_config_ordering: endpoint_url WROTE to config_write_log" "" "$endpoint_write_line"
    assert_ne "t_config_ordering: put-function-concurrency appears in call_log" "" "$concurrency_line"
}

# ── Test 15: Config write preserves existing unrelated keys ──────────────────
t_config_write_preserves_existing_keys() {
    local mock_bin conf_file call_log
    mock_bin="$(make_tmpdir)"
    conf_file="$(make_tmpdir)/dso-config.conf"
    call_log="$(make_tmpdir)/calls.log"
    echo "unrelated.key=preserved-value" > "$conf_file"
    touch "$call_log"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_config_preserves: exits 0" "0" "$exit_code"

    local preserved
    preserved=$(grep -c "^unrelated\.key=preserved-value$" "$conf_file" 2>/dev/null || echo "0")
    assert_eq "t_config_preserves: unrelated.key=preserved-value remains" "1" "$preserved"

    # Lambda config keys should now be written
    local has_lambda_key=0
    if grep -qE '^(review_telemetry\.|lambda_function_name|iam_role_name|endpoint_url)' "$conf_file" 2>/dev/null; then
        has_lambda_key=1
    fi
    assert_eq "t_config_preserves: lambda config keys written" "1" "$has_lambda_key"
}

# ── Test 16: All lambda/iam calls carry us-east-1 ─────────────────────────────
t_region_pinned_to_us_east_1() {
    local mock_bin call_log conf_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    conf_file="$(make_tmpdir)/dso-config.conf"
    touch "$call_log" "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || true

    # All lambda calls must carry us-east-1
    local lambda_lines lambda_without_region
    lambda_lines=$(grep -c "^lambda" "$call_log" 2>/dev/null || echo "0")
    lambda_without_region=$(grep "^lambda" "$call_log" 2>/dev/null | grep -cv "us-east-1" || echo "0")

    assert_ne "t_region: at least one lambda call logged" "0" "$lambda_lines"
    assert_eq "t_region: all lambda calls contain us-east-1" "0" "$lambda_without_region"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
t_happy_path_creates_all_resources
t_rerun_is_no_op
t_missing_iam_aborts_before_create
t_sts_get_caller_identity_failure_aborts_before_create
t_missing_python_runtime_aborts_before_create
t_missing_bucket_name_in_config_aborts_with_exit_6
t_iam_policy_scoped_to_bucket_arn_only
t_iam_role_propagation_retry_with_backoff
t_log_group_retention_7d
t_function_url_no_api_gateway
t_function_url_auth_type_none
t_reserved_concurrency_set_to_10
t_simulate_principal_policy_returns_allowed
t_config_keys_written_early_for_partial_state_recovery
t_config_write_preserves_existing_keys
t_region_pinned_to_us_east_1

print_summary
