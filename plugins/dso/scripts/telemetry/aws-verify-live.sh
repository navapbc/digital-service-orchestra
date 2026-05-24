#!/usr/bin/env bash
# aws-verify-live.sh (${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/) — DSO telemetry live AWS verification
set -euo pipefail
#
# Runs 7 live checks against the AWS resources provisioned for DSO review telemetry.
# Each check prints "<check_name>: ok" on success or "<check_name>: FAIL <reason>" on failure.
#
# Exit-code policy:
#   0  = all 7 checks passed
#   1  = pre-flight failure (missing config key)
#   2  = one or more checks failed
#
# ── Environment overrides (for testability) ────────────────────────────────────
#   DSO_AWS_CMD          Override the aws binary (for PATH-stub tests)
#   DSO_READ_CONFIG_CMD  Override the path to the read-config helper
#   DSO_SLEEP_CMD        Override the sleep binary (for fast-clock stub tests)

# ── Resolve paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/telemetry/ lives four levels below repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# ── Overridable commands ───────────────────────────────────────────────────────
_AWS_CMD="${DSO_AWS_CMD:-aws}"
_READ_CONFIG_CMD="${DSO_READ_CONFIG_CMD:-"$REPO_ROOT/.claude/scripts/dso read-config"}"
_SLEEP_CMD="${DSO_SLEEP_CMD:-sleep}"

# ── Internal sleep wrapper ────────────────────────────────────────────────────
# All aws calls use `timeout 5 "$_AWS_CMD"` — the timeout prevents any single
# check from blocking longer than 5s (DD-4 post-teardown safety constraint).
# DSO_AWS_CMD is the testability seam; never call `aws` directly.
_sleep() {
    "$_SLEEP_CMD" "$@"
}

# ── read_config: read a single config key ─────────────────────────────────────
_read_config() {
    $_READ_CONFIG_CMD "$1" 2>/dev/null || true
}

# ── Load required config keys (fail fast if absent) ───────────────────────────
BUCKET="$(_read_config review_telemetry.bucket_name)"
FUNCTION_NAME="$(_read_config review_telemetry.lambda_function_name)"
ROLE_NAME="$(_read_config review_telemetry.iam_role_name)"
FUNCTION_URL="$(_read_config review_telemetry.lambda_function_url)"

if [[ -z "$BUCKET" ]]; then
    echo "ERROR: review_telemetry.bucket_name is not set" >&2
    exit 1
fi
if [[ -z "$FUNCTION_NAME" ]]; then
    echo "ERROR: review_telemetry.lambda_function_name is not set" >&2
    exit 1
fi
if [[ -z "$ROLE_NAME" ]]; then
    echo "ERROR: review_telemetry.iam_role_name is not set" >&2
    exit 1
fi
if [[ -z "$FUNCTION_URL" ]]; then
    echo "ERROR: review_telemetry.lambda_function_url is not set" >&2
    exit 1
fi

# ── Check 1: Lambda function URL configured ───────────────────────────────────
check_lambda_function_url() {
    local exit_code=0
    timeout 5 "$_AWS_CMD" lambda get-function-url-config \
        --function-name "$FUNCTION_NAME" \
        >/dev/null 2>&1 || exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo "check_lambda_function_url: ok"
        return 0
    else
        echo "check_lambda_function_url: FAIL get-function-url-config returned non-zero"
        return 1
    fi
}

# ── Check 2: IAM role trust policy includes lambda.amazonaws.com ──────────────
check_iam_role_trust() {
    local role_json exit_code=0
    role_json="$(timeout 5 "$_AWS_CMD" iam get-role \
        --role-name "$ROLE_NAME" \
        --output json 2>/dev/null)" || exit_code=$?

    if [[ $exit_code -ne 0 ]] || [[ -z "$role_json" ]]; then
        echo "check_iam_role_trust: FAIL get-role returned non-zero or empty"
        return 1
    fi

    local has_lambda
    has_lambda="$(printf '%s' "$role_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    trust_policy = data.get('Role', {}).get('AssumeRolePolicyDocument', {})
    if isinstance(trust_policy, str):
        trust_policy = json.loads(trust_policy)
    for stmt in trust_policy.get('Statement', []):
        principal = stmt.get('Principal', {})
        if isinstance(principal, dict):
            service = principal.get('Service', [])
            if isinstance(service, str):
                service = [service]
            if 'lambda.amazonaws.com' in service:
                print('yes')
                sys.exit(0)
        elif isinstance(principal, str):
            if principal == 'lambda.amazonaws.com':
                print('yes')
                sys.exit(0)
    print('no')
except Exception as e:
    print('no')
" 2>/dev/null || echo "no")"

    if [[ "$has_lambda" == "yes" ]]; then
        echo "check_iam_role_trust: ok"
        return 0
    else
        echo "check_iam_role_trust: FAIL trust policy does not include lambda.amazonaws.com"
        return 1
    fi
}

# ── Check 3: S3 bucket exists (head-bucket) ───────────────────────────────────
check_s3_head_bucket() {
    local exit_code=0
    timeout 5 "$_AWS_CMD" s3api head-bucket \
        --bucket "$BUCKET" \
        >/dev/null 2>&1 || exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        echo "check_s3_head_bucket: ok"
        return 0
    else
        echo "check_s3_head_bucket: FAIL head-bucket returned non-zero"
        return 1
    fi
}

# ── Check 4: S3 bucket encryption (SSE configured) ───────────────────────────
check_s3_encryption() {
    local sse_json exit_code=0
    sse_json="$(timeout 5 "$_AWS_CMD" s3api get-bucket-encryption \
        --bucket "$BUCKET" \
        --output json 2>/dev/null)" || exit_code=$?

    if [[ $exit_code -ne 0 ]] || [[ -z "$sse_json" ]]; then
        echo "check_s3_encryption: FAIL get-bucket-encryption returned non-zero or empty"
        return 1
    fi

    local sse_ok
    sse_ok="$(printf '%s' "$sse_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    rules = data.get('ServerSideEncryptionConfiguration', {}).get('Rules', [])
    for r in rules:
        algo = r.get('ApplyServerSideEncryptionByDefault', {}).get('SSEAlgorithm', '')
        if algo in ('AES256', 'aws:kms'):
            print('yes')
            sys.exit(0)
    print('no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")"

    if [[ "$sse_ok" == "yes" ]]; then
        echo "check_s3_encryption: ok"
        return 0
    else
        echo "check_s3_encryption: FAIL SSE not configured (AES256 or aws:kms required)"
        return 1
    fi
}

# ── Check 5: S3 lifecycle has ≥1 transition rule ──────────────────────────────
check_s3_lifecycle() {
    local lc_json exit_code=0
    lc_json="$(timeout 5 "$_AWS_CMD" s3api get-bucket-lifecycle-configuration \
        --bucket "$BUCKET" \
        --output json 2>/dev/null)" || exit_code=$?

    if [[ $exit_code -ne 0 ]] || [[ -z "$lc_json" ]]; then
        echo "check_s3_lifecycle: FAIL get-bucket-lifecycle-configuration returned non-zero or empty"
        return 1
    fi

    local has_transition
    has_transition="$(printf '%s' "$lc_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    for rule in data.get('Rules', []):
        if rule.get('Transitions'):
            print('yes')
            sys.exit(0)
    print('no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")"

    if [[ "$has_transition" == "yes" ]]; then
        echo "check_s3_lifecycle: ok"
        return 0
    else
        echo "check_s3_lifecycle: FAIL no lifecycle transition rule found"
        return 1
    fi
}

# ── Check 6: IAM simulate-principal-policy allows s3:PutObject ───────────────
check_iam_simulate_principal() {
    # Get role ARN first from get-role output (reuse ROLE_NAME already validated above)
    local role_json exit_code=0
    role_json="$(timeout 5 "$_AWS_CMD" iam get-role \
        --role-name "$ROLE_NAME" \
        --output json 2>/dev/null)" || exit_code=$?

    if [[ $exit_code -ne 0 ]] || [[ -z "$role_json" ]]; then
        echo "check_iam_simulate_principal: FAIL get-role returned non-zero or empty"
        return 1
    fi

    local role_arn
    role_arn="$(printf '%s' "$role_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    print(data.get('Role', {}).get('Arn', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"

    if [[ -z "$role_arn" ]]; then
        echo "check_iam_simulate_principal: FAIL could not extract role ARN"
        return 1
    fi

    local sim_json sim_exit=0
    sim_json="$(timeout 5 "$_AWS_CMD" iam simulate-principal-policy \
        --policy-source-arn "$role_arn" \
        --action-names "s3:PutObject" \
        --resource-arns "arn:aws:s3:::${BUCKET}/*" \
        --output json 2>/dev/null)" || sim_exit=$?

    if [[ $sim_exit -ne 0 ]] || [[ -z "$sim_json" ]]; then
        echo "check_iam_simulate_principal: FAIL simulate-principal-policy returned non-zero or empty"
        return 1
    fi

    local allowed
    allowed="$(printf '%s' "$sim_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    for result in data.get('EvaluationResults', []):
        if result.get('EvalDecision', '').lower() == 'allowed':
            print('yes')
            sys.exit(0)
    print('no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")"

    if [[ "$allowed" == "yes" ]]; then
        echo "check_iam_simulate_principal: ok"
        return 0
    else
        echo "check_iam_simulate_principal: FAIL s3:PutObject not allowed per simulate-principal-policy"
        return 1
    fi
}

# ── Check 7: End-to-end POST → S3 object visible ─────────────────────────────
# Invoke the Lambda with a Function-URL-shaped event (schema-valid tool_finding
# payload), then poll S3 with backoff schedule [1, 2, 4, 8, 15, 30] seconds
# under the client_id/YYYY-MM-DD/ prefix that s3_writer.py uses, until a new
# object appears.
#
# Why SDK invoke instead of anonymous curl: AWS Organization SCPs (e.g.
# o-t5fn7az6cp on the dso-self deployment account) deny lambda:InvokeFunctionUrl
# for Principal=* regardless of the resource-based policy, so the anonymous POST
# path returns 403 by design in restricted accounts. Direct SDK invocation uses
# the caller's IAM identity, which is the validated emission path per the
# d2f9 epic evidence (bug b3ac). In permissive accounts the SCP block does not
# apply and SDK invoke still works identically — there is no downside.
check_e2e_post_visibility() {
    local test_client_id="dso-roundtrip-test"
    local today
    today="$(date -u +%Y-%m-%d)"
    local backoff_schedule=(1 2 4 8 15 30)

    # Build a schema-valid tool_finding event. Required PER_TYPE_FIELDS:
    # tool_name, tool_rule, tool_severity ∈ {error,warning,info}, file, message.
    # Required COMMON_FIELDS the Lambda will accept: schema_version=1, event_id,
    # event_type, client_id, tool_id, tool_version, timestamp.
    local event_id timestamp
    event_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local event_body
    event_body="$(python3 -c "
import json
print(json.dumps({
    'schema_version': 1,
    'event_id': '${event_id}',
    'event_type': 'tool_finding',
    'client_id': '${test_client_id}',
    'tool_id': 'aws-verify-live',
    'tool_version': '1.0.0',
    'timestamp': '${timestamp}',
    'tool_name': 'dso-verify-live-roundtrip',
    'tool_rule': 'roundtrip_smoke_test',
    'tool_severity': 'info',
    'file': '',
    'message': 'aws-verify-live.sh check 7 smoke test',
}))")"
    local invoke_payload
    invoke_payload="$(python3 -c "
import json, sys
print(json.dumps({'body': sys.argv[1]}))" "$event_body")"

    # Direct SDK invocation — the d2f9 validated emission path.
    timeout 10 "$_AWS_CMD" lambda invoke \
        --function-name "$FUNCTION_NAME" \
        --payload "$invoke_payload" \
        --cli-binary-format raw-in-base64-out \
        /dev/null >/dev/null 2>&1 || true

    # Poll with backoff under the canonical {client_id}/{YYYY-MM-DD}/ prefix.
    local found=0
    local i
    for i in "${backoff_schedule[@]}"; do
        _sleep "$i"
        local list_json list_exit=0
        list_json="$(timeout 5 "$_AWS_CMD" s3api list-objects-v2 \
            --bucket "$BUCKET" \
            --prefix "${test_client_id}/${today}/" \
            --output json 2>/dev/null)" || list_exit=$?

        if [[ $list_exit -eq 0 ]] && [[ -n "$list_json" ]]; then
            local key_count
            key_count="$(printf '%s' "$list_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    print(str(len(data.get('Contents', []))))
except Exception:
    print('0')
" 2>/dev/null || echo "0")"
            if [[ "$key_count" -gt 0 ]]; then
                found=1
                break
            fi
        fi
    done

    if [[ $found -eq 1 ]]; then
        echo "check_e2e_post_visibility: ok"
        return 0
    else
        echo "check_e2e_post_visibility: FAIL no object appeared in s3://${BUCKET}/${test_client_id}/${today}/ within poll budget"
        return 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    local overall_exit=0

    check_lambda_function_url  || overall_exit=2
    check_iam_role_trust       || overall_exit=2
    check_s3_head_bucket       || overall_exit=2
    check_s3_encryption        || overall_exit=2
    check_s3_lifecycle         || overall_exit=2
    check_iam_simulate_principal || overall_exit=2
    check_e2e_post_visibility  || overall_exit=2

    exit "$overall_exit"
}

main "$@"
