#!/usr/bin/env bash
# aws-setup-bucket.sh (${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/) — DSO telemetry S3 bucket setup
set -euo pipefail
#
# Sets up the DSO review-telemetry S3 bucket with:
#   - Public-access block (all 4 flags)
#   - SSE (AES256)
#   - Lifecycle: transition to GLACIER_IR after 90 days
#   - Bucket policy: Allow PutObject from lambda_role_arn; Deny all others
#
# Partial-state recovery contract:
#   If the script exits non-zero after ensure_bucket succeeds, the bucket
#   exists in AWS AND review_telemetry.bucket_name is written to dso-config.conf.
#   Re-running the script is safe: ensure_bucket is idempotent (head-bucket
#   check), and write_config_key is idempotent (rewrites stale values).
#   Any subsequent ensure_* step that failed can be retried by re-running the
#   full script — no manual cleanup required.
#
# ── Exit codes ─────────────────────────────────────────────────────────────────
#   0  = all resources created / verified; config written
#   4  = aws sts get-caller-identity failed (credential/auth error)
#   5  = missing required IAM permissions (no s3api resources created)
#   6  = missing required config key (review_telemetry.lambda_role_arn or
#        review_telemetry.bucket_name_prefix)
#   1  = unexpected error in an ensure_* step (bucket name printed to stderr)
#
# ── Environment overrides (for testability) ────────────────────────────────────
#   DSO_AWS_CMD          Override the aws binary to use (for PATH-stub tests)
#   DSO_READ_CONFIG_CMD  Override the path to the read-config helper
#   DSO_CONFIG_FILE      Override the path to dso-config.conf (for tests)

# ── Resolve paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/telemetry/ lives four levels below repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# ── Overridable commands ───────────────────────────────────────────────────────
_AWS_CMD="${DSO_AWS_CMD:-aws}"
_READ_CONFIG_CMD="${DSO_READ_CONFIG_CMD:-"$REPO_ROOT/.claude/scripts/dso read-config"}"
_CONFIG_FILE="${DSO_CONFIG_FILE:-"$REPO_ROOT/.claude/dso-config.conf"}"

# ── Internal aws wrapper (pins region) ────────────────────────────────────────
_aws() {
    "$_AWS_CMD" "$@"
}

_aws_s3api() {
    local subcmd="$1"
    shift
    "$_AWS_CMD" s3api "$subcmd" --region us-east-1 "$@"
}

# ── read_config: read a single config key ─────────────────────────────────────
_read_config() {
    $_READ_CONFIG_CMD "$1" 2>/dev/null || true
}

# ── write_config_key: sourced from telemetry-lib.sh (shared with aws-setup-lambda.sh)
# shellcheck source=telemetry-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/telemetry-lib.sh"

# ── Preflight: verify credentials ─────────────────────────────────────────────
preflight_credentials() {
    local raw exit_code=0
    raw="$(_aws sts get-caller-identity --output json 2>&1)" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "ERROR: 'aws sts get-caller-identity' failed — credential/auth error." >&2
        echo "aws output: ${raw}" >&2
        echo "Remediation: ensure AWS credentials are configured (aws configure, AWS_PROFILE, or IAM role)." >&2
        exit 4
    fi
    _ACCOUNT_ID="$(echo "$raw" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['Account'])" 2>/dev/null || true)"
    if [[ -z "${_ACCOUNT_ID:-}" ]]; then
        _ACCOUNT_ID="$(_read_config review_telemetry.aws_account_id)"
    fi
}

# ── Preflight: verify IAM permissions via simulate-principal-policy ───────────
# Uses the same pattern as aws-setup-lambda.sh:152 and aws-verify-live.sh:242 —
# simulate-principal-policy works for both IAM users and assumed roles, whereas
# list-attached-user-policies requires --user-name and breaks for role principals.
preflight_iam() {
    local caller_arn raw
    caller_arn="$(_aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
    if [[ -z "${caller_arn:-}" ]]; then
        echo "ERROR: Unable to resolve caller ARN from sts get-caller-identity." >&2
        exit 5
    fi

    raw="$(_aws iam simulate-principal-policy \
        --policy-source-arn "$caller_arn" \
        --action-names s3:CreateBucket s3:PutBucketPublicAccessBlock s3:PutEncryptionConfiguration s3:PutLifecycleConfiguration s3:PutBucketPolicy \
        --output json 2>/dev/null || true)"

    local denied_actions
    denied_actions="$(echo "$raw" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    results = data.get('EvaluationResults', [])
    denied = [r['EvalActionName'] for r in results if r.get('EvalDecision') != 'allowed']
    print(','.join(denied))
except Exception:
    print('s3:CreateBucket,s3:PutBucketPublicAccessBlock,s3:PutEncryptionConfiguration,s3:PutLifecycleConfiguration,s3:PutBucketPolicy')
" 2>/dev/null || echo "s3:CreateBucket,s3:PutBucketPublicAccessBlock,s3:PutEncryptionConfiguration,s3:PutLifecycleConfiguration,s3:PutBucketPolicy")"

    if [[ -n "${denied_actions:-}" ]]; then
        echo "ERROR: Missing required IAM permissions." >&2
        echo "Required: s3:CreateBucket, s3:PutBucketPublicAccessBlock, s3:PutEncryptionConfiguration, s3:PutLifecycleConfiguration, s3:PutBucketPolicy" >&2
        echo "Denied: ${denied_actions}" >&2
        exit 5
    fi
}

# ── Config fail-fast: required keys ───────────────────────────────────────────
load_config() {
    _LAMBDA_ROLE_ARN="$(_read_config review_telemetry.lambda_role_arn)"
    if [[ -z "${_LAMBDA_ROLE_ARN:-}" ]]; then
        echo "ERROR: Missing required config key: review_telemetry.lambda_role_arn" >&2
        echo "Set review_telemetry.lambda_role_arn in .claude/dso-config.conf before running." >&2
        exit 6
    fi

    _BUCKET_NAME_PREFIX="$(_read_config review_telemetry.bucket_name_prefix)"
    if [[ -z "${_BUCKET_NAME_PREFIX:-}" ]]; then
        echo "ERROR: Missing required config key: review_telemetry.bucket_name_prefix" >&2
        echo "Set review_telemetry.bucket_name_prefix in .claude/dso-config.conf before running." >&2
        exit 6
    fi

    # Derive bucket name: existing config value OR prefix + account suffix
    _BUCKET_NAME="$(_read_config review_telemetry.bucket_name)"
    if [[ -z "${_BUCKET_NAME:-}" ]]; then
        _BUCKET_NAME="${_BUCKET_NAME_PREFIX}-${_ACCOUNT_ID:-review}"
    fi
}

# ── ensure_bucket ──────────────────────────────────────────────────────────────
ensure_bucket() {
    local exit_code=0
    _aws_s3api head-bucket --bucket "$_BUCKET_NAME" >/dev/null 2>&1 || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "INFO: Creating bucket: $_BUCKET_NAME"
        _aws_s3api create-bucket \
            --bucket "$_BUCKET_NAME" \
            >/dev/null
    fi
}

# ── ensure_public_access_block ────────────────────────────────────────────────
ensure_public_access_block() {
    local raw exit_code=0
    raw="$(_aws_s3api get-public-access-block --bucket "$_BUCKET_NAME" 2>&1)" || exit_code=$?

    # Check if all 4 flags are true — if not (or missing), put them
    local all_set=0
    if [[ $exit_code -eq 0 ]] && [[ -n "$raw" ]]; then
        all_set="$(echo "$raw" | python3 -c "
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
    print(1 if all(flags) else 0)
except Exception:
    print(0)
" 2>/dev/null || echo "0")"
    fi

    if [[ "${all_set}" != "1" ]]; then
        _aws_s3api put-public-access-block \
            --bucket "$_BUCKET_NAME" \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
            >/dev/null
    fi
}

# ── ensure_sse ────────────────────────────────────────────────────────────────
ensure_sse() {
    local raw exit_code=0
    raw="$(_aws_s3api get-bucket-encryption --bucket "$_BUCKET_NAME" 2>&1)" || exit_code=$?

    local aes_ok=0
    if [[ $exit_code -eq 0 ]] && [[ -n "$raw" ]]; then
        aes_ok="$(echo "$raw" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    rules = data.get('ServerSideEncryptionConfiguration', {}).get('Rules', [])
    for r in rules:
        algo = r.get('ApplyServerSideEncryptionByDefault', {}).get('SSEAlgorithm', '')
        if algo == 'AES256':
            print(1)
            sys.exit(0)
    print(0)
except Exception:
    print(0)
" 2>/dev/null || echo "0")"
    fi

    if [[ "${aes_ok}" != "1" ]]; then
        _aws_s3api put-bucket-encryption \
            --bucket "$_BUCKET_NAME" \
            --server-side-encryption-configuration \
            '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
            >/dev/null
    fi
}

# ── ensure_lifecycle ──────────────────────────────────────────────────────────
ensure_lifecycle() {
    local raw exit_code=0
    raw="$(_aws_s3api get-bucket-lifecycle-configuration --bucket "$_BUCKET_NAME" 2>&1)" || exit_code=$?

    local lifecycle_ok=0
    if [[ $exit_code -eq 0 ]] && [[ -n "$raw" ]]; then
        lifecycle_ok="$(echo "$raw" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    rules = data.get('Rules', [])
    for r in rules:
        transitions = r.get('Transitions', [])
        for t in transitions:
            if t.get('Days') == 90 and t.get('StorageClass') == 'GLACIER_IR' and r.get('Status') == 'Enabled':
                print(1)
                sys.exit(0)
    print(0)
except Exception:
    print(0)
" 2>/dev/null || echo "0")"
    fi

    if [[ "${lifecycle_ok}" != "1" ]]; then
        _aws_s3api put-bucket-lifecycle-configuration \
            --bucket "$_BUCKET_NAME" \
            --lifecycle-configuration \
            '{"Rules":[{"ID":"dso-telemetry-archive","Status":"Enabled","Filter":{"Prefix":""},"Transitions":[{"Days":90,"StorageClass":"GLACIER_IR"}]}]}' \
            >/dev/null
    fi
}

# ── ensure_policy ─────────────────────────────────────────────────────────────
ensure_policy() {
    # Build the expected policy JSON
    local policy
    policy="$(python3 -c "
import json, sys

role_arn = sys.argv[1]
bucket = sys.argv[2]

policy = {
    'Version': '2012-10-17',
    'Statement': [
        {
            'Sid': 'AllowLambdaPutObject',
            'Effect': 'Allow',
            'Principal': {'AWS': role_arn},
            'Action': 's3:PutObject',
            'Resource': 'arn:aws:s3:::' + bucket + '/*'
        },
        {
            'Sid': 'DenyNonLambdaPutObject',
            'Effect': 'Deny',
            'Principal': '*',
            'Action': 's3:PutObject',
            'Resource': 'arn:aws:s3:::' + bucket + '/*',
            'Condition': {
                'StringNotEquals': {
                    'aws:PrincipalArn': role_arn
                }
            }
        }
    ]
}
print(json.dumps(policy))
" "$_LAMBDA_ROLE_ARN" "$_BUCKET_NAME" 2>/dev/null)"

    if [[ -z "$policy" ]]; then
        echo "ERROR: Failed to build bucket policy JSON" >&2
        exit 1
    fi

    local raw exit_code=0
    raw="$(_aws_s3api get-bucket-policy --bucket "$_BUCKET_NAME" 2>&1)" || exit_code=$?

    # Always put the policy (get-bucket-policy stub returns empty on fresh bucket)
    local policy_ok=0
    if [[ $exit_code -eq 0 ]] && [[ -n "$raw" ]]; then
        # Compare existing policy to desired (simple string match after normalize)
        local existing_policy
        existing_policy="$(echo "$raw" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    p = data.get('Policy', '')
    if p:
        print(json.dumps(json.loads(p), sort_keys=True))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo "")"
        local desired_normalized
        desired_normalized="$(echo "$policy" | python3 -c "
import sys, json
try:
    print(json.dumps(json.loads(sys.stdin.read()), sort_keys=True))
except Exception:
    print('')
" 2>/dev/null || echo "")"
        if [[ -n "$existing_policy" ]] && [[ "$existing_policy" == "$desired_normalized" ]]; then
            policy_ok=1
        fi
    fi

    if [[ "${policy_ok}" != "1" ]]; then
        _aws_s3api put-bucket-policy \
            --bucket "$_BUCKET_NAME" \
            --policy "$policy" \
            >/dev/null
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    # Phase 1: Preflight (credentials + IAM)
    preflight_credentials
    preflight_iam

    # Phase 2: Load and validate config (fail-fast on missing keys)
    load_config

    # Phase 3: Resource creation — ordered per partial-state recovery contract
    # Step 1: Create bucket
    if ! ensure_bucket; then
        echo "ERROR: ensure_bucket failed for bucket: $_BUCKET_NAME" >&2
        exit 1
    fi

    # Step 2: Write config key IMMEDIATELY after bucket exists (partial-state recovery)
    write_config_key "review_telemetry.bucket_name" "$_BUCKET_NAME"

    # Step 3: Apply public-access block (MUST precede policy)
    if ! ensure_public_access_block; then
        echo "ERROR: ensure_public_access_block failed for bucket: $_BUCKET_NAME" >&2
        exit 1
    fi

    # Step 4: Apply SSE
    if ! ensure_sse; then
        echo "ERROR: ensure_sse failed for bucket: $_BUCKET_NAME" >&2
        exit 1
    fi

    # Step 5: Apply lifecycle
    if ! ensure_lifecycle; then
        echo "ERROR: ensure_lifecycle failed for bucket: $_BUCKET_NAME" >&2
        exit 1
    fi

    # Step 6: Apply bucket policy (after public-access block)
    if ! ensure_policy; then
        echo "ERROR: ensure_policy failed for bucket: $_BUCKET_NAME" >&2
        exit 1
    fi

    echo "OK: DSO telemetry bucket setup complete: $_BUCKET_NAME"
}

main "$@"
