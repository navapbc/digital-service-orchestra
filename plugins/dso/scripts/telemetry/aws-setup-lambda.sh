#!/usr/bin/env bash
# aws-setup-lambda.sh (${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/) — DSO telemetry Lambda setup
set -euo pipefail
#
# Sets up the DSO review-telemetry Lambda function with:
#   - IAM execution role (s3:PutObject scoped to bucket ARN only)
#   - CloudWatch log group with 7-day retention
#   - Lambda function (python3.13 runtime) with 3-attempt retry for IAM propagation
#   - Function URL (auth-type NONE — public POST endpoint per epic d2f9)
#   - Reserved concurrency = 10
#   - Post-create IAM simulate-principal-policy verification
#
# Partial-state recovery contract:
#   write_config_key is called EARLY (after each resource is created) so that
#   re-runs can skip already-created resources. Config keys written:
#     review_telemetry.iam_role_name    — after ensure_iam_role
#     review_telemetry.lambda_function_name — after ensure_lambda_function
#     review_telemetry.endpoint_url     — after ensure_function_url
#
# ── Exit codes ─────────────────────────────────────────────────────────────────
#   0  = all resources created / verified; config written
#   4  = aws sts get-caller-identity failed (credential/auth error)
#   5  = missing required IAM permissions (simulate-principal-policy Deny)
#   6  = missing required config key (review_telemetry.bucket_name)
#   1  = unexpected error in an ensure_* step
#
# ── Environment overrides (for testability) ────────────────────────────────────
#   DSO_AWS_CMD          Override the aws binary (for PATH-stub tests)
#   DSO_READ_CONFIG_CMD  Override the path to the read-config helper
#   DSO_CONFIG_FILE      Override the path to dso-config.conf (for tests — NEVER write to real config)
#   DSO_SLEEP_CMD        Override sleep command (default: sleep) for retry testability
#   CONFIG_WRITE_LOG     If set, write_config_key appends "WROTE <key>" for ordering assertions

# ── Constants ──────────────────────────────────────────────────────────────────
readonly LAMBDA_FUNCTION_NAME="dso-telemetry-review"
readonly LAMBDA_ROLE_NAME="dso-telemetry-lambda-role"
readonly LAMBDA_LOG_GROUP="/aws/lambda/${LAMBDA_FUNCTION_NAME}"
readonly LAMBDA_REGION="us-east-1"
readonly LAMBDA_RUNTIME="python3.13"
readonly LAMBDA_HANDLER="handler.lambda_handler"
readonly LAMBDA_RESERVED_CONCURRENCY=10
readonly LOG_RETENTION_DAYS=7
readonly MAX_CREATE_ATTEMPTS=3
readonly LAMBDA_TIMEOUT_SECONDS=30

# ── Resolve paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/telemetry/ lives four levels below repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# ── Overridable commands ───────────────────────────────────────────────────────
_AWS_CMD="${DSO_AWS_CMD:-aws}"
_READ_CONFIG_CMD="${DSO_READ_CONFIG_CMD:-"$REPO_ROOT/.claude/scripts/dso read-config"}"
_CONFIG_FILE="${DSO_CONFIG_FILE:-"$REPO_ROOT/.claude/dso-config.conf"}"
_SLEEP_CMD="${DSO_SLEEP_CMD:-sleep}"

# ── Internal wrappers ─────────────────────────────────────────────────────────

# _aws_lambda: invoke aws lambda with region pinned
_aws_lambda() {
    local subcmd="$1"
    shift
    "$_AWS_CMD" lambda "$subcmd" --region "$LAMBDA_REGION" "$@"
}

# _aws_iam: invoke aws iam (no region needed for global service, but pass for consistency)
_aws_iam() {
    local subcmd="$1"
    shift
    "$_AWS_CMD" iam "$subcmd" "$@"
}

# _aws_logs: invoke aws logs with region pinned
_aws_logs() {
    local subcmd="$1"
    shift
    "$_AWS_CMD" logs "$subcmd" --region "$LAMBDA_REGION" "$@"
}

# _aws_sts: invoke aws sts
_aws_sts() {
    local subcmd="$1"
    shift
    "$_AWS_CMD" sts "$subcmd" "$@"
}

# ── read_config: read a single config key ─────────────────────────────────────
_read_config() {
    $_READ_CONFIG_CMD "$1" 2>/dev/null || true
}

# ── write_config_key: atomic temp+rename; preserves all other keys ────────────
write_config_key() {
    local key="$1" value="$2"
    local conf_file="$_CONFIG_FILE"
    local tmp_file
    tmp_file="$(mktemp "${conf_file}.XXXXXX")"

    if [[ -f "$conf_file" ]]; then
        if grep -q "^${key}=" "$conf_file" 2>/dev/null; then
            # Replace existing line, preserve all others
            grep -v "^${key}=" "$conf_file" > "$tmp_file" || true
        else
            # Copy existing content
            cp "$conf_file" "$tmp_file"
        fi
    fi

    # Append the key=value line
    echo "${key}=${value}" >> "$tmp_file"

    # Atomic rename
    mv "$tmp_file" "$conf_file"

    # Log the write for ordering assertions (CONFIG_WRITE_LOG env override)
    if [[ -n "${CONFIG_WRITE_LOG:-}" ]] && [[ "${CONFIG_WRITE_LOG}" != "/dev/null" ]]; then
        echo "WROTE ${key}" >> "${CONFIG_WRITE_LOG}"
    fi
}

# ── Preflight: verify credentials ─────────────────────────────────────────────
preflight_credentials() {
    local raw exit_code=0
    raw="$(_aws_sts get-caller-identity --output json 2>&1)" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "ERROR: 'aws sts get-caller-identity' failed — credential/auth error." >&2
        echo "aws output: ${raw}" >&2
        echo "Remediation: ensure AWS credentials are configured (aws configure, AWS_PROFILE, or IAM role)." >&2
        exit 4
    fi
}

# ── Preflight: verify IAM permissions via simulate-principal-policy ────────────
preflight_iam() {
    # We need our own caller ARN to simulate
    local caller_arn
    caller_arn="$(_aws_sts get-caller-identity --output json 2>/dev/null \
        | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('Arn',''))" 2>/dev/null || true)"

    local required_actions=(
        "iam:CreateRole"
        "iam:AttachRolePolicy"
        "iam:PutRolePolicy"
        "iam:PassRole"
        "lambda:CreateFunction"
        "lambda:GetFunction"
        "lambda:CreateFunctionUrlConfig"
        "lambda:PutFunctionConcurrency"
        "logs:CreateLogGroup"
        "logs:PutRetentionPolicy"
    )

    local raw exit_code=0
    raw="$(_aws_iam simulate-principal-policy \
        --policy-source-arn "${caller_arn:-arn:aws:iam::123456789012:user/current}" \
        --action-names "${required_actions[@]}" \
        --output json 2>&1)" || exit_code=$?

    # Check for any implicitDeny or explicitDeny
    local denied_action
    denied_action="$(echo "$raw" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    results = data.get('EvaluationResults', [])
    for r in results:
        if r.get('EvalDecision', '') != 'allowed':
            print(r.get('EvalActionName', 'unknown'))
            break
except Exception:
    pass
" 2>/dev/null || true)"

    if [[ -n "$denied_action" ]]; then
        echo "ERROR: Missing required IAM permission: ${denied_action}" >&2
        echo "Denied action: ${denied_action}" >&2
        echo "Grant the required IAM permissions before running this script." >&2
        exit 5
    fi
}

# ── Preflight: verify configured Lambda runtime is in the supported set ──────
# AWS Lambda has no `list-runtimes` API; runtime support is documented, not
# API-queryable. We sanity-check the configured LAMBDA_RUNTIME against a known
# set. If AWS later deprecates a runtime in the set, the downstream
# create-function call surfaces the actual error with the AWS-native message.
preflight_python_runtime() {
    local known_supported=(python3.9 python3.10 python3.11 python3.12 python3.13)
    local rt
    for rt in "${known_supported[@]}"; do
        if [[ "$LAMBDA_RUNTIME" == "$rt" ]]; then
            return 0
        fi
    done
    echo "ERROR: configured LAMBDA_RUNTIME='${LAMBDA_RUNTIME}' is not in the known-supported set." >&2
    echo "Supported: ${known_supported[*]}" >&2
    echo "Update LAMBDA_RUNTIME, or add the new runtime to known_supported after verifying against AWS Lambda documentation." >&2
    exit 1
}

# ── Config fail-fast: required keys ──────────────────────────────────────────
load_config() {
    _BUCKET_NAME="$(_read_config review_telemetry.bucket_name)"
    if [[ -z "${_BUCKET_NAME:-}" ]]; then
        echo "ERROR: Missing required config key: review_telemetry.bucket_name" >&2
        echo "Run aws-setup-bucket.sh first to create the telemetry bucket." >&2
        exit 6
    fi
    _BUCKET_ARN="arn:aws:s3:::${_BUCKET_NAME}"
}

# ── ensure_iam_role ───────────────────────────────────────────────────────────
ensure_iam_role() {
    local exit_code=0
    local get_output
    get_output="$(_aws_iam get-role --role-name "$LAMBDA_ROLE_NAME" --output json 2>&1)" || exit_code=$?

    local role_arn
    if [[ $exit_code -ne 0 ]]; then
        echo "INFO: Creating IAM role: $LAMBDA_ROLE_NAME"
        local trust_policy
        trust_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

        local create_output
        create_output="$(_aws_iam create-role \
            --role-name "$LAMBDA_ROLE_NAME" \
            --assume-role-policy-document "$trust_policy" \
            --output json 2>&1)"

        role_arn="$(echo "$create_output" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('Role',{}).get('Arn',''))" 2>/dev/null || true)"
    else
        echo "INFO: IAM role already exists: $LAMBDA_ROLE_NAME"
        role_arn="$(echo "$get_output" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('Role',{}).get('Arn',''))" 2>/dev/null || true)"
    fi

    _ROLE_ARN="${role_arn:-arn:aws:iam::123456789012:role/${LAMBDA_ROLE_NAME}}"

    # Always apply the inline policy to ensure correct scope (idempotent):
    # s3:PutObject scoped to bucket ARN only (no s3:*, no Resource:"*")
    local inline_policy
    inline_policy="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"${_BUCKET_ARN}/*\"}]}"

    _aws_iam put-role-policy \
        --role-name "$LAMBDA_ROLE_NAME" \
        --policy-name "dso-telemetry-s3-putobject" \
        --policy-document "$inline_policy" \
        >/dev/null 2>&1
}

# ── ensure_log_group ──────────────────────────────────────────────────────────
ensure_log_group() {
    local raw exit_code=0
    raw="$(_aws_logs describe-log-groups \
        --log-group-name-prefix "$LAMBDA_LOG_GROUP" \
        --output json 2>&1)" || exit_code=$?

    local group_exists=0
    if [[ $exit_code -eq 0 ]] && [[ -n "$raw" ]]; then
        group_exists="$(echo "$raw" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    groups = data.get('logGroups', [])
    for g in groups:
        if g.get('logGroupName', '') == '$LAMBDA_LOG_GROUP':
            print(1)
            sys.exit(0)
    print(0)
except Exception:
    print(0)
" 2>/dev/null || echo "0")"
    fi

    if [[ "$group_exists" != "1" ]]; then
        echo "INFO: Creating log group: $LAMBDA_LOG_GROUP"
        # Tolerate ResourceAlreadyExistsException (eventually-consistent race)
        local create_exit=0
        local create_out
        create_out="$(_aws_logs create-log-group \
            --log-group-name "$LAMBDA_LOG_GROUP" \
            --output json 2>&1)" || create_exit=$?
        if [[ $create_exit -ne 0 ]]; then
            if echo "$create_out" | grep -q "ResourceAlreadyExistsException"; then
                echo "INFO: Log group already exists (race): $LAMBDA_LOG_GROUP"
            else
                echo "ERROR: create-log-group failed: $create_out" >&2
                exit 1
            fi
        fi

        _aws_logs put-retention-policy \
            --log-group-name "$LAMBDA_LOG_GROUP" \
            --retention-in-days 7 \
            >/dev/null 2>&1
    fi
}

# ── ensure_lambda_function ────────────────────────────────────────────────────
# 3-attempt retry with backoff for IAM propagation delay.
# Always sets the canonical Handler (LAMBDA_HANDLER) and TELEMETRY_BUCKET env on
# create AND reconciles them on idempotent re-run — fixes bugs c1c2 + 404b
# (handler name mismatched the deployed zip; env var was missing → handler.py
# raised KeyError on first invoke).
ensure_lambda_function() {
    local exit_code=0
    _aws_lambda get-function \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --output json >/dev/null 2>&1 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "INFO: Lambda function already exists: $LAMBDA_FUNCTION_NAME — reconciling Handler + Environment"
        # Bug c1c2 + 404b idempotent reconcile: ensure existing function has
        # the canonical handler and TELEMETRY_BUCKET env var, even if it was
        # created by an older version of this script (which hardcoded
        # lambda_function.handler and omitted the env var).
        _aws_lambda update-function-configuration \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --handler "$LAMBDA_HANDLER" \
            --timeout "$LAMBDA_TIMEOUT_SECONDS" \
            --environment "Variables={TELEMETRY_BUCKET=$_BUCKET_NAME}" \
            --output json >/dev/null 2>&1 || true
        return 0
    fi

    echo "INFO: Creating Lambda function: $LAMBDA_FUNCTION_NAME"

    # Build a non-empty placeholder zip. /dev/null is not a zip archive (bug
    # 2c82); AWS additionally rejects empty zips with "Uploaded file must be
    # a non-empty zip" (bug 2c82b). The placeholder ships a minimal handler.py
    # stub matching LAMBDA_HANDLER's expected module/function so the function
    # is invokable from the moment it is created — aws-deploy-handler.sh
    # later overwrites it with the real payload.
    local zip_placeholder
    zip_placeholder="$(mktemp /tmp/dso-lambda-placeholder.XXXXXX.zip)"
    python3 - "$zip_placeholder" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('handler.py', 'def lambda_handler(event, context):\n    return {"statusCode": 202, "body": ""}\n')
PYEOF
    # shellcheck disable=SC2064
    trap "rm -f '$zip_placeholder'" EXIT

    local attempt=0
    local backoff=2
    while [[ $attempt -lt $MAX_CREATE_ATTEMPTS ]]; do
        attempt=$(( attempt + 1 ))
        local create_exit=0
        local create_out
        create_out="$(_aws_lambda create-function \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --runtime "$LAMBDA_RUNTIME" \
            --role "$_ROLE_ARN" \
            --handler "$LAMBDA_HANDLER" \
            --timeout "$LAMBDA_TIMEOUT_SECONDS" \
            --environment "Variables={TELEMETRY_BUCKET=$_BUCKET_NAME}" \
            --zip-file "fileb://$zip_placeholder" \
            --output json 2>&1)" || create_exit=$?

        if [[ $create_exit -eq 0 ]]; then
            echo "INFO: Lambda function created on attempt $attempt (handler=$LAMBDA_HANDLER, TELEMETRY_BUCKET=$_BUCKET_NAME)"
            return 0
        fi

        # Retry on IAM propagation error (InvalidParameterValue: role cannot be assumed)
        if echo "$create_out" | grep -qiE "InvalidParameterValue|role.*cannot be assumed|cannot be assumed"; then
            if [[ $attempt -lt $MAX_CREATE_ATTEMPTS ]]; then
                echo "INFO: IAM propagation delay — retrying create-function in ${backoff}s (attempt $attempt/$MAX_CREATE_ATTEMPTS)" >&2
                $_SLEEP_CMD "$backoff" 2>/dev/null || true
                backoff=$(( backoff * 2 ))
                continue
            fi
        fi

        echo "ERROR: create-function failed on attempt $attempt: $create_out" >&2
        exit 1
    done

    echo "ERROR: create-function failed after $MAX_CREATE_ATTEMPTS attempts" >&2
    exit 1
}

# ── ensure_function_url ───────────────────────────────────────────────────────
ensure_function_url() {
    local exit_code=0
    local raw
    raw="$(_aws_lambda get-function-url-config \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --output json 2>&1)" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "INFO: Function URL already exists for: $LAMBDA_FUNCTION_NAME"
        _FUNCTION_URL="$(echo "$raw" | python3 -c \
            "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('FunctionUrl',''))" 2>/dev/null || true)"
        return 0
    fi

    echo "INFO: Creating Function URL for: $LAMBDA_FUNCTION_NAME"
    local url_output
    url_output="$(_aws_lambda create-function-url-config \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --auth-type NONE \
        --output json 2>&1)"

    _FUNCTION_URL="$(echo "$url_output" | python3 -c \
        "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('FunctionUrl',''))" 2>/dev/null || true)"
}

# ── ensure_reserved_concurrency ───────────────────────────────────────────────
ensure_reserved_concurrency() {
    local exit_code=0
    local raw
    raw="$(_aws_lambda get-function-concurrency \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --output json 2>&1)" || exit_code=$?

    # Numeric comparison: check if ReservedConcurrentExecutions == 10
    # Must NOT use empty-string check (0 = explicitly blocked, not same as unset)
    local current_concurrency
    current_concurrency="$(echo "$raw" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    val = data.get('ReservedConcurrentExecutions', None)
    if val is None:
        print('')
    else:
        print(int(val))
except Exception:
    print('')
" 2>/dev/null || echo "")"

    if [[ "$current_concurrency" == "$LAMBDA_RESERVED_CONCURRENCY" ]]; then
        echo "INFO: Reserved concurrency already set to $LAMBDA_RESERVED_CONCURRENCY"
        return 0
    fi

    echo "INFO: Setting reserved concurrency to $LAMBDA_RESERVED_CONCURRENCY"
    _aws_lambda put-function-concurrency \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --reserved-concurrent-executions 10 \
        --output json >/dev/null 2>&1
}

# ── verify_simulate_principal_policy ─────────────────────────────────────────
# Post-create assertion (dd-4): verify role can s3:PutObject on the bucket
verify_simulate_principal_policy() {
    echo "INFO: Verifying IAM role permissions via simulate-principal-policy"
    local raw exit_code=0
    raw="$(_aws_iam simulate-principal-policy \
        --policy-source-arn "$_ROLE_ARN" \
        --action-names "s3:PutObject" \
        --resource-arns "${_BUCKET_ARN}/*" \
        --output json 2>&1)" || exit_code=$?

    local decision
    decision="$(echo "$raw" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    results = data.get('EvaluationResults', [])
    if results:
        print(results[0].get('EvalDecision', 'unknown'))
    else:
        print('unknown')
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")"

    if [[ "$decision" != "allowed" ]]; then
        echo "ERROR: Post-create IAM verify failed: s3:PutObject on ${_BUCKET_ARN}/* — decision: ${decision}" >&2
        exit 5
    fi

    echo "INFO: IAM verify passed: s3:PutObject allowed on ${_BUCKET_ARN}/*"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    # Phase 1: Preflight (credentials + IAM permissions + python runtime)
    preflight_credentials
    preflight_iam
    preflight_python_runtime

    # Phase 2: Load and validate config (fail-fast on missing keys)
    load_config

    # Phase 3: Resource creation — ordered per partial-state recovery contract

    # Step 1: Create IAM execution role
    ensure_iam_role

    # Step 2: Write iam_role_name EARLY (before create-function for recovery)
    write_config_key "review_telemetry.iam_role_name" "$LAMBDA_ROLE_NAME"

    # Step 3: Create CloudWatch log group
    ensure_log_group

    # Step 4: Create Lambda function (with retry for IAM propagation)
    ensure_lambda_function

    # Step 5: Write lambda_function_name EARLY (before URL create for recovery)
    write_config_key "review_telemetry.lambda_function_name" "$LAMBDA_FUNCTION_NAME"

    # Step 6: Create Function URL
    ensure_function_url

    # Step 7: Write endpoint_url EARLY (before concurrency for recovery)
    write_config_key "review_telemetry.endpoint_url" "${_FUNCTION_URL:-}"

    # Step 8: Set reserved concurrency
    ensure_reserved_concurrency

    # Step 9: Post-create verification
    verify_simulate_principal_policy

    echo "OK: DSO telemetry Lambda setup complete: $LAMBDA_FUNCTION_NAME"
}

main "$@"
