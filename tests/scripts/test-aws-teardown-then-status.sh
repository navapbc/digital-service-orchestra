#!/usr/bin/env bash
set -euo pipefail
# tests/scripts/test-aws-teardown-then-status.sh
# Integration test: run aws-teardown.sh then aws-status.sh, assert all resources absent.
#
# Uses a stateful aws mock backed by STATE_FILE (mktemp, grep-based).
# Delete calls append a resource sentinel to STATE_FILE.
# Status/get calls check STATE_FILE to determine presence.
#
# Cases covered:
#   1. t_pre_teardown_resources_present    — before teardown, all 4 resources present;
#                                           attribute fields (lifecycle_tier, function_url,
#                                           trust_policy_includes_lambda, retention_days) present
#   2. t_teardown_exits_0                  — aws-teardown.sh --user-approved exits 0
#   3. t_post_teardown_all_absent_exit_0   — aws-status.sh exits 0 after teardown;
#                                           all 4 resources present==false;
#                                           schema_version==1; metrics.last_24h_event_count==0
#
# Usage: bash tests/scripts/test-aws-teardown-then-status.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEARDOWN_SCRIPT="$REPO_ROOT/plugins/dso/scripts/telemetry/aws-teardown.sh"
STATUS_SCRIPT="$REPO_ROOT/plugins/dso/scripts/telemetry/aws-status.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-aws-teardown-then-status.sh ==="

# ── Shared constants ───────────────────────────────────────────────────────────
BUCKET_NAME="test-bucket"
FUNCTION_NAME="test-fn"
ROLE_NAME="test-role"
# Log group is derived by the scripts — not a separate config key
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"

# ── Setup: STATE_FILE and SANDBOX ─────────────────────────────────────────────
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/aws-composition-test.XXXXXX")"
STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/mock-state.XXXXXX")"
trap 'rm -rf "$SANDBOX"; rm -f "$STATE_FILE"' EXIT

# ── Write the dso (read-config) stub ──────────────────────────────────────────
mkdir -p "$SANDBOX/.claude/scripts"
# shellcheck disable=SC2016
cat > "$SANDBOX/.claude/scripts/dso" << 'STUB'
#!/usr/bin/env bash
# Minimal dso stub: handles "read-config <key>" (invoked as: dso read-config <key>)
# aws-teardown.sh and aws-status.sh call: $_READ_CONFIG_CMD <key>
# DSO_READ_CONFIG_CMD is set to "$SANDBOX/.claude/scripts/dso read-config"
# so argv: $1=read-config, $2=<key>  — but the scripts call it as a single command
# with one argument, so we respond to $1 directly.
key="${1:-}"
case "$key" in
    review_telemetry.bucket_name)          echo "test-bucket" ;;
    review_telemetry.lambda_function_name) echo "test-fn" ;;
    review_telemetry.iam_role_name)        echo "test-role" ;;
    *) echo "" ;;
esac
STUB
chmod +x "$SANDBOX/.claude/scripts/dso"

# ── Write the stateful aws mock ────────────────────────────────────────────────
# Delete calls: append resource sentinel to STATE_FILE
# Status/get calls: grep STATE_FILE to determine if resource was deleted
#
# Sentinels written on delete:
#   "test-fn"     — lambda deleted
#   "test-role"   — iam role deleted
#   "test-bucket" — s3 bucket deleted
#   "test-log"    — log group deleted
#
# State checks use grep -q <sentinel> "$STATE_FILE".
# shellcheck disable=SC2016
cat > "$SANDBOX/aws" << AWSMOCK
#!/usr/bin/env bash
STATE_FILE="${STATE_FILE}"

args="\$*"

# ── Lambda ────────────────────────────────────────────────────────────────────
# Note: more-specific patterns must come before broader ones (e.g.
# get-function-url-config before get-function) to avoid early-match shadowing.
case "\$args" in
  *"lambda delete-function"*)
    echo "test-fn" >> "\$STATE_FILE"
    exit 0
    ;;
  *"lambda get-function-url-config"*)
    grep -q 'test-fn' "\$STATE_FILE" && exit 1
    echo '{"FunctionUrl":"https://abc123.lambda-url.us-east-1.on.aws/"}'
    exit 0
    ;;
  *"lambda get-function-concurrency"*)
    grep -q 'test-fn' "\$STATE_FILE" && exit 1
    echo '{"ReservedConcurrentExecutions":10}'
    exit 0
    ;;
  *"lambda get-function"*)
    grep -q 'test-fn' "\$STATE_FILE" && exit 1
    echo '{"Configuration":{"FunctionName":"test-fn","FunctionArn":"arn:aws:lambda:us-east-1:123456789012:function:test-fn"}}'
    exit 0
    ;;
esac

# ── IAM ───────────────────────────────────────────────────────────────────────
case "\$args" in
  *"iam delete-role "*)
    echo "test-role" >> "\$STATE_FILE"
    exit 0
    ;;
  *"iam delete-role-policy"*|*"iam detach-role-policy"*)
    exit 0
    ;;
  *"iam list-role-policies"*)
    echo "inline-policy-1"
    exit 0
    ;;
  *"iam list-attached-role-policies"*)
    echo "arn:aws:iam::aws:policy/AWSLambdaBasicExecutionRole"
    exit 0
    ;;
  *"iam get-role"*)
    grep -q 'test-role' "\$STATE_FILE" && exit 1
    echo '{"Role":{"RoleName":"test-role","AssumeRolePolicyDocument":{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}}}'
    exit 0
    ;;
esac

# ── S3 ────────────────────────────────────────────────────────────────────────
case "\$args" in
  *"s3api delete-bucket"*)
    echo "test-bucket" >> "\$STATE_FILE"
    exit 0
    ;;
  *"s3api delete-objects"*|*"s3 rm"*)
    exit 0
    ;;
  *"s3api list-object-versions"*)
    echo '{"Versions":null,"DeleteMarkers":null}'
    exit 0
    ;;
  *"s3api head-bucket"*)
    grep -q 'test-bucket' "\$STATE_FILE" && exit 1
    exit 0
    ;;
  *"s3api get-bucket-lifecycle-configuration"*)
    grep -q 'test-bucket' "\$STATE_FILE" && exit 1
    echo '{"Rules":[{"Status":"Enabled","Transitions":[{"Days":90,"StorageClass":"GLACIER_IR"}]}]}'
    exit 0
    ;;
  *"s3api get-public-access-block"*)
    grep -q 'test-bucket' "\$STATE_FILE" && exit 1
    echo '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}}'
    exit 0
    ;;
  *"s3api get-bucket-encryption"*)
    grep -q 'test-bucket' "\$STATE_FILE" && exit 1
    echo '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}'
    exit 0
    ;;
esac

# ── CloudWatch Logs ───────────────────────────────────────────────────────────
case "\$args" in
  *"logs delete-log-group"*)
    echo "test-log" >> "\$STATE_FILE"
    exit 0
    ;;
  *"logs describe-log-groups"*)
    grep -q 'test-log' "\$STATE_FILE" && exit 1
    echo '{"logGroups":[{"logGroupName":"/aws/lambda/test-fn","retentionInDays":7}]}'
    exit 0
    ;;
esac

# ── CloudWatch Metrics ────────────────────────────────────────────────────────
case "\$args" in
  *"cloudwatch get-metric-statistics"*)
    echo '{"Datapoints":[]}'
    exit 0
    ;;
esac

# Default: succeed silently
exit 0
AWSMOCK
chmod +x "$SANDBOX/aws"

# Export PATH so the mock aws is found; DSO_AWS_CMD and DSO_READ_CONFIG_CMD
# override the scripts' default resolution without requiring PATH mutation.
DSO_AWS_CMD="$SANDBOX/aws"
DSO_READ_CONFIG_CMD="$SANDBOX/.claude/scripts/dso"

# ── Test 1: Pre-teardown — all resources present, attribute fields populated ──
t_pre_teardown_resources_present() {
    echo ""
    echo "-- t_pre_teardown_resources_present --"

    # Ensure STATE_FILE is empty (no deletions yet)
    : > "$STATE_FILE"

    local exit_code=0
    local out
    out="$(DSO_AWS_CMD="$DSO_AWS_CMD" \
        DSO_READ_CONFIG_CMD="$DSO_READ_CONFIG_CMD" \
        bash "$STATUS_SCRIPT" 2>/dev/null)" || exit_code=$?

    assert_eq "pre_teardown: aws-status.sh exits 0" "0" "$exit_code"

    # schema_version == 1
    local schema_version
    schema_version="$(printf '%s' "$out" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('schema_version','missing'))" \
        2>/dev/null || echo "missing")"
    assert_eq "pre_teardown: schema_version==1" "1" "$schema_version"

    # All 4 resources present==true
    for resource in bucket lambda iam_role log_group; do
        local present_val
        present_val="$(printf '%s' "$out" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print('true' if d.get('$resource',{}).get('present') is True else 'false')" \
            2>/dev/null || echo "false")"
        assert_eq "pre_teardown: $resource.present==true" "true" "$present_val"
    done

    # bucket.lifecycle_tier present (non-empty string)
    local lifecycle_tier
    lifecycle_tier="$(printf '%s' "$out" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('bucket',{}).get('lifecycle_tier',''))" \
        2>/dev/null || echo "")"
    assert_ne "pre_teardown: bucket.lifecycle_tier is non-empty" "" "$lifecycle_tier"

    # lambda.function_url present (non-null)
    local function_url
    function_url="$(printf '%s' "$out" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); v=d.get('lambda',{}).get('function_url'); print('present' if v is not None else 'null')" \
        2>/dev/null || echo "null")"
    assert_eq "pre_teardown: lambda.function_url is present" "present" "$function_url"

    # iam_role.trust_policy_includes_lambda present (boolean)
    local trust_policy
    trust_policy="$(printf '%s' "$out" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); v=d.get('iam_role',{}).get('trust_policy_includes_lambda'); print('present' if v is not None else 'missing')" \
        2>/dev/null || echo "missing")"
    assert_eq "pre_teardown: iam_role.trust_policy_includes_lambda is present" "present" "$trust_policy"

    # log_group.retention_days present (non-null)
    local retention_days
    retention_days="$(printf '%s' "$out" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); v=d.get('log_group',{}).get('retention_days'); print('present' if v is not None else 'missing')" \
        2>/dev/null || echo "missing")"
    assert_eq "pre_teardown: log_group.retention_days is present" "present" "$retention_days"
}

# ── Test 2: aws-teardown.sh --user-approved exits 0 ──────────────────────────
t_teardown_exits_0() {
    echo ""
    echo "-- t_teardown_exits_0 --"

    local exit_code=0
    DSO_AWS_CMD="$DSO_AWS_CMD" \
        DSO_READ_CONFIG_CMD="$DSO_READ_CONFIG_CMD" \
        bash "$TEARDOWN_SCRIPT" --user-approved >/dev/null 2>&1 || exit_code=$?

    assert_eq "teardown: exits 0" "0" "$exit_code"

    # Verify STATE_FILE contains all 4 sentinels (all deletes ran)
    local has_fn has_role has_bucket has_log
    has_fn=0;    grep -q 'test-fn'     "$STATE_FILE" 2>/dev/null && has_fn=1     || true
    has_role=0;  grep -q 'test-role'   "$STATE_FILE" 2>/dev/null && has_role=1   || true
    has_bucket=0;grep -q 'test-bucket' "$STATE_FILE" 2>/dev/null && has_bucket=1 || true
    has_log=0;   grep -q 'test-log'    "$STATE_FILE" 2>/dev/null && has_log=1    || true

    assert_eq "teardown: lambda sentinel written" "1" "$has_fn"
    assert_eq "teardown: iam-role sentinel written" "1" "$has_role"
    assert_eq "teardown: bucket sentinel written" "1" "$has_bucket"
    assert_eq "teardown: log-group sentinel written" "1" "$has_log"
}

# ── Test 3: Post-teardown — all absent, exit 0, schema_version==1, count==0 ──
t_post_teardown_all_absent_exit_0() {
    echo ""
    echo "-- t_post_teardown_all_absent_exit_0 --"

    local exit_code=0
    local out
    out="$(DSO_AWS_CMD="$DSO_AWS_CMD" \
        DSO_READ_CONFIG_CMD="$DSO_READ_CONFIG_CMD" \
        bash "$STATUS_SCRIPT" 2>/dev/null)" || exit_code=$?

    assert_eq "post_teardown: aws-status.sh exits 0" "0" "$exit_code"

    # schema_version == 1
    local schema_version
    schema_version="$(printf '%s' "$out" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('schema_version','missing'))" \
        2>/dev/null || echo "missing")"
    assert_eq "post_teardown: schema_version==1" "1" "$schema_version"

    # All 4 resources present==false
    for resource in bucket lambda iam_role log_group; do
        local present_val
        present_val="$(printf '%s' "$out" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print('false' if d.get('$resource',{}).get('present') is False else 'true')" \
            2>/dev/null || echo "true")"
        assert_eq "post_teardown: $resource.present==false" "false" "$present_val"
    done

    # metrics.last_24h_event_count == 0
    local event_count
    event_count="$(printf '%s' "$out" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('metrics',{}).get('last_24h_event_count','missing'))" \
        2>/dev/null || echo "missing")"
    assert_eq "post_teardown: metrics.last_24h_event_count==0" "0" "$event_count"
}

# ── Run all tests in composition order ────────────────────────────────────────
t_pre_teardown_resources_present
t_teardown_exits_0
t_post_teardown_all_absent_exit_0

print_summary
