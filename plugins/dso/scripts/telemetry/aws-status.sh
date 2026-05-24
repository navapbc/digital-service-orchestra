#!/usr/bin/env bash
# aws-status.sh (${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/) — DSO telemetry AWS resource status reporter
set -euo pipefail
#
# Probes the four core AWS resources (S3 bucket, Lambda function, IAM role,
# CloudWatch log group) and emits a single JSON document to stdout per
# ${CLAUDE_PLUGIN_ROOT}/docs/contracts/aws-status-schema.md (schema_version: 1).
#
# Exit-code policy:
#   0  = always (read-only reporter; absent resources are reported as {present:false})
#   Non-zero exit means the script itself failed (e.g. missing config keys).
#
# ── Environment overrides (for testability) ────────────────────────────────────
#   DSO_AWS_CMD          Override the aws binary (for PATH-stub tests)
#   DSO_READ_CONFIG_CMD  Override the path to the read-config helper

# ── Resolve paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Derive REPO_ROOT via git (preferred per test-plugin-scripts-no-relative-paths
# policy). PROJECT_ROOT env override keeps tests / unusual contexts working.
REPO_ROOT="${PROJECT_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")}"

SCHEMA_VERSION=1

# ── Overridable commands ───────────────────────────────────────────────────────
_AWS_CMD="${DSO_AWS_CMD:-aws}"
_READ_CONFIG_CMD="${DSO_READ_CONFIG_CMD:-"$REPO_ROOT/.claude/scripts/dso read-config"}"

# ── Internal aws wrapper ───────────────────────────────────────────────────────
_aws() {
    "$_AWS_CMD" "$@"
}

# ── read_config: read a single config key ─────────────────────────────────────
_read_config() {
    $_READ_CONFIG_CMD "$1" 2>/dev/null || true
}

# ── Load required config keys (fail fast if absent) ───────────────────────────
BUCKET="$(_read_config review_telemetry.bucket_name)"
FUNCTION_NAME="$(_read_config review_telemetry.lambda_function_name)"
ROLE_NAME="$(_read_config review_telemetry.iam_role_name)"

for _var in BUCKET FUNCTION_NAME ROLE_NAME; do
    if [[ -z "${!_var}" ]]; then
        echo "ERROR: config key for ${_var} is not set" >&2
        exit 1
    fi
done

# Log group is derived from function name — NOT a separate config key
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"

# ── Probe: S3 bucket ──────────────────────────────────────────────────────────
probe_bucket() {
    local exit_code=0

    # Check bucket existence
    _aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        printf '{"present":false}'
        return
    fi

    # Lifecycle tier
    local lifecycle_json lifecycle_tier="unknown"
    lifecycle_json="$(_aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --output json 2>/dev/null || true)"
    if [[ -n "$lifecycle_json" ]]; then
        lifecycle_tier="$(printf '%s' "$lifecycle_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    for rule in data.get('Rules', []):
        for t in rule.get('Transitions', []):
            sc = t.get('StorageClass', '')
            if sc:
                # Normalize: GLACIER_IR -> Glacier-IR
                print('Glacier-IR' if sc == 'GLACIER_IR' else sc)
                sys.exit(0)
    print('unknown')
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")"
    fi

    # Public access block (all 4 flags must be true)
    local pab_json pab_enabled=false
    pab_json="$(_aws s3api get-public-access-block --bucket "$BUCKET" --output json 2>/dev/null || true)"
    if [[ -n "$pab_json" ]]; then
        pab_enabled="$(printf '%s' "$pab_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    cfg = data.get('PublicAccessBlockConfiguration', {})
    flags = [
        cfg.get('BlockPublicAcls', False),
        cfg.get('IgnorePublicAcls', False),
        cfg.get('BlockPublicPolicy', False),
        cfg.get('RestrictPublicBuckets', False),
    ]
    print('true' if all(flags) else 'false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")"
    fi

    # SSE
    local sse_json sse_enabled=false
    sse_json="$(_aws s3api get-bucket-encryption --bucket "$BUCKET" --output json 2>/dev/null || true)"
    if [[ -n "$sse_json" ]]; then
        sse_enabled="$(printf '%s' "$sse_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    rules = data.get('ServerSideEncryptionConfiguration', {}).get('Rules', [])
    for r in rules:
        algo = r.get('ApplyServerSideEncryptionByDefault', {}).get('SSEAlgorithm', '')
        if algo in ('AES256', 'aws:kms'):
            print('true')
            sys.exit(0)
    print('false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")"
    fi

    jq -n \
        --arg name "$BUCKET" \
        --arg lifecycle_tier "$lifecycle_tier" \
        --argjson pab "$pab_enabled" \
        --argjson sse "$sse_enabled" \
        '{present: true, name: $name, lifecycle_tier: $lifecycle_tier, public_access_block_enabled: $pab, sse_enabled: $sse}'
}

# ── Probe: Lambda function ────────────────────────────────────────────────────
probe_lambda() {
    local fn_json exit_code=0
    fn_json="$(_aws lambda get-function --function-name "$FUNCTION_NAME" --region us-east-1 --output json 2>/dev/null)" || exit_code=$?
    if [[ $exit_code -ne 0 ]] || [[ -z "$fn_json" ]]; then
        printf '{"present":false}'
        return
    fi

    # Function URL
    local url_json function_url="null"
    local url_exit=0
    url_json="$(_aws lambda get-function-url-config --function-name "$FUNCTION_NAME" --region us-east-1 --output json 2>/dev/null)" || url_exit=$?
    if [[ $url_exit -eq 0 ]] && [[ -n "$url_json" ]]; then
        function_url="$(printf '%s' "$url_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    url = data.get('FunctionUrl', '')
    print(json.dumps(url) if url else 'null')
except Exception:
    print('null')
" 2>/dev/null || echo "null")"
    fi

    # Reserved concurrency
    local concurrency_json reserved_concurrency="null"
    local conc_exit=0
    concurrency_json="$(_aws lambda get-function-concurrency --function-name "$FUNCTION_NAME" --region us-east-1 --output json 2>/dev/null)" || conc_exit=$?
    if [[ $conc_exit -eq 0 ]] && [[ -n "$concurrency_json" ]]; then
        reserved_concurrency="$(printf '%s' "$concurrency_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    val = data.get('ReservedConcurrentExecutions')
    print(str(val) if val is not None else 'null')
except Exception:
    print('null')
" 2>/dev/null || echo "null")"
    fi

    jq -n \
        --arg name "$FUNCTION_NAME" \
        --argjson function_url "$function_url" \
        --argjson reserved_concurrency "$reserved_concurrency" \
        '{present: true, name: $name, function_url: $function_url, reserved_concurrency: $reserved_concurrency}'
}

# ── Probe: IAM role ───────────────────────────────────────────────────────────
probe_iam_role() {
    local role_json exit_code=0
    role_json="$(_aws iam get-role --role-name "$ROLE_NAME" --output json 2>/dev/null)" || exit_code=$?
    if [[ $exit_code -ne 0 ]] || [[ -z "$role_json" ]]; then
        printf '{"present":false}'
        return
    fi

    # Check trust policy includes lambda.amazonaws.com
    local trust_includes_lambda=false
    trust_includes_lambda="$(printf '%s' "$role_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    trust_policy_str = data.get('Role', {}).get('AssumeRolePolicyDocument', '')
    if isinstance(trust_policy_str, str):
        trust_policy = json.loads(trust_policy_str)
    else:
        trust_policy = trust_policy_str
    for stmt in trust_policy.get('Statement', []):
        principal = stmt.get('Principal', {})
        if isinstance(principal, dict):
            service = principal.get('Service', [])
            if isinstance(service, str):
                service = [service]
            if 'lambda.amazonaws.com' in service:
                print('true')
                sys.exit(0)
        elif isinstance(principal, str):
            if principal == 'lambda.amazonaws.com':
                print('true')
                sys.exit(0)
    print('false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")"

    jq -n \
        --arg name "$ROLE_NAME" \
        --argjson trust "$trust_includes_lambda" \
        '{present: true, name: $name, trust_policy_includes_lambda: $trust}'
}

# ── Probe: CloudWatch log group ───────────────────────────────────────────────
probe_log_group() {
    local lg_json exit_code=0
    lg_json="$(_aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --output json 2>/dev/null)" || exit_code=$?
    if [[ $exit_code -ne 0 ]] || [[ -z "$lg_json" ]]; then
        printf '{"present":false}'
        return
    fi

    # Check the exact log group exists
    local found_group
    found_group="$(printf '%s' "$lg_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    groups = data.get('logGroups', [])
    target = sys.argv[1]
    for g in groups:
        if g.get('logGroupName') == target:
            print(json.dumps(g))
            sys.exit(0)
    print('')
except Exception:
    print('')
" "$LOG_GROUP" 2>/dev/null || echo "")"

    if [[ -z "$found_group" ]]; then
        printf '{"present":false}'
        return
    fi

    local retention_days
    retention_days="$(printf '%s' "$found_group" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    val = data.get('retentionInDays')
    print(str(val) if val is not None else '0')
except Exception:
    print('0')
" 2>/dev/null || echo "0")"

    jq -n \
        --arg name "$LOG_GROUP" \
        --argjson retention_days "$retention_days" \
        '{present: true, name: $name, retention_days: $retention_days}'
}

# ── Metrics: last 24h event count via CloudWatch GetMetricStatistics ──────────
probe_metrics() {
    local event_count=0

    local start_time end_time
    end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    # macOS: -v-24H; GNU: -d '24 hours ago'
    start_time="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"

    if [[ -n "$start_time" ]]; then
        local metric_json metric_exit=0
        metric_json="$(_aws cloudwatch get-metric-statistics \
            --namespace AWS/Lambda \
            --metric-name Invocations \
            --dimensions "Name=FunctionName,Value=${FUNCTION_NAME}" \
            --statistics Sum \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --period 86400 \
            --output json 2>/dev/null)" || metric_exit=$?

        if [[ $metric_exit -eq 0 ]] && [[ -n "$metric_json" ]]; then
            event_count="$(printf '%s' "$metric_json" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    datapoints = data.get('Datapoints', [])
    if datapoints:
        total = sum(int(d.get('Sum', 0)) for d in datapoints)
        print(str(total))
    else:
        print('0')
except Exception:
    print('0')
" 2>/dev/null || echo "0")"
        fi
    fi

    printf '%s' "$event_count"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    # Probe all resources independently — failures produce {present:false}
    local bucket_json lambda_json iam_role_json log_group_json event_count

    bucket_json="$(probe_bucket 2>/dev/null || printf '{"present":false}')"
    lambda_json="$(probe_lambda 2>/dev/null || printf '{"present":false}')"
    iam_role_json="$(probe_iam_role 2>/dev/null || printf '{"present":false}')"
    log_group_json="$(probe_log_group 2>/dev/null || printf '{"present":false}')"
    event_count="$(probe_metrics 2>/dev/null || echo "0")"

    # Ensure event_count is a valid integer
    if ! [[ "$event_count" =~ ^[0-9]+$ ]]; then
        event_count=0
    fi

    jq -n \
        --argjson schema_version "$SCHEMA_VERSION" \
        --argjson bucket "$bucket_json" \
        --argjson lambda "$lambda_json" \
        --argjson iam_role "$iam_role_json" \
        --argjson log_group "$log_group_json" \
        --argjson event_count "$event_count" \
        '{
            schema_version: $schema_version,
            bucket: $bucket,
            lambda: $lambda,
            iam_role: $iam_role,
            log_group: $log_group,
            metrics: {last_24h_event_count: $event_count}
        }'
}

main "$@"
