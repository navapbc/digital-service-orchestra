#!/usr/bin/env bash
# aws-teardown.sh (${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/) — DSO telemetry AWS resource teardown
set -euo pipefail
#
# Permanently deletes all AWS resources created by the aws-setup-* scripts:
#   - Lambda function
#   - IAM execution role (inline + managed policies detached first)
#   - S3 bucket (all object versions purged first for versioned buckets)
#   - CloudWatch log group
#
# Resource names are read from review_telemetry.* config keys.
# The log group name is derived as /aws/lambda/<lambda_function_name> —
# it is NOT a separate config key.
#
# KNOWN LIMITATION: This script does not remove config keys from dso-config.conf.
# After running, stale review_telemetry.* entries will remain in dso-config.conf.
# Remove them manually or re-run the relevant aws-setup-* scripts to reprovision.
#
# Safety gate: --user-approved must be passed as the first argument. Without it
# the script exits 1 immediately and performs no AWS calls.
#
# Each delete call uses `(aws ... 2>/dev/null) || true` — already-absent resources
# are not treated as failures.
#
# ── Environment overrides (for testability) ────────────────────────────────────
#   DSO_AWS_CMD          Override the aws binary (for PATH-stub tests)
#   DSO_READ_CONFIG_CMD  Override the path to the read-config helper

# ── Resolve paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/telemetry/ lives four levels below repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# ── Overridable commands ───────────────────────────────────────────────────────
_AWS_CMD="${DSO_AWS_CMD:-aws}"
_READ_CONFIG_CMD="${DSO_READ_CONFIG_CMD:-"$REPO_ROOT/.claude/scripts/dso read-config"}"

# ── Safety gate ───────────────────────────────────────────────────────────────
if [[ "${1:-}" != "--user-approved" ]]; then
    echo "ERROR: This script permanently deletes AWS resources. Pass --user-approved to confirm." >&2
    exit 1
fi

# ── Read resource names from config ───────────────────────────────────────────
FUNCTION_NAME="$(${_READ_CONFIG_CMD} review_telemetry.lambda_function_name 2>/dev/null || true)"
ROLE_NAME="$(${_READ_CONFIG_CMD} review_telemetry.iam_role_name 2>/dev/null || true)"
BUCKET="$(${_READ_CONFIG_CMD} review_telemetry.bucket_name 2>/dev/null || true)"

# Log group is derived from function name — not a separate config key
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"

# ── Confirmation summary ───────────────────────────────────────────────────────
echo "Deleting resources:"
echo "  Lambda:                 ${FUNCTION_NAME}"
echo "  IAM Role:               ${ROLE_NAME}"
echo "  S3 Bucket:              ${BUCKET}"
echo "  CloudWatch Log Group:   ${LOG_GROUP}"

# ── 1. Lambda function ────────────────────────────────────────────────────────
("${_AWS_CMD}" lambda delete-function \
    --function-name "${FUNCTION_NAME}" \
    --region us-east-1 \
    2>/dev/null) || true

# ── 2. IAM role ───────────────────────────────────────────────────────────────
# Must detach/delete all policies before delete-role or it fails with
# DeleteConflict. List inline policies first, then managed policies.

# 2a. Inline policies
while IFS= read -r policy_name; do
    [[ -n "${policy_name}" ]] || continue
    ("${_AWS_CMD}" iam delete-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-name "${policy_name}" \
        2>/dev/null) || true
done < <("${_AWS_CMD}" iam list-role-policies \
    --role-name "${ROLE_NAME}" \
    --query 'PolicyNames' \
    --output text \
    2>/dev/null || true)

# 2b. Managed (attached) policies
while IFS= read -r policy_arn; do
    [[ -n "${policy_arn}" ]] || continue
    ("${_AWS_CMD}" iam detach-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-arn "${policy_arn}" \
        2>/dev/null) || true
done < <("${_AWS_CMD}" iam list-attached-role-policies \
    --role-name "${ROLE_NAME}" \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text \
    2>/dev/null || true)

# 2c. Delete the role itself
("${_AWS_CMD}" iam delete-role \
    --role-name "${ROLE_NAME}" \
    2>/dev/null) || true

# ── 3. S3 bucket ──────────────────────────────────────────────────────────────
# For versioned buckets, plain s3 rm cannot remove object versions or delete
# markers. Enumerate all versions and delete markers, then delete the bucket.

# 3a. Purge object versions (if any)
# shellcheck disable=SC2016  # JMESPath backticks are literal, not shell expansions
_versions_json="$("${_AWS_CMD}" s3api list-object-versions \
    --bucket "${BUCKET}" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}, Quiet: `true`}' \
    --output json \
    2>/dev/null || echo '{}')"

if echo "${_versions_json}" | grep -q '"Key"'; then
    ("${_AWS_CMD}" s3api delete-objects \
        --bucket "${BUCKET}" \
        --delete "${_versions_json}" \
        2>/dev/null) || true
fi

# 3b. Purge delete markers (if any)
# shellcheck disable=SC2016  # JMESPath backticks are literal, not shell expansions
_markers_json="$("${_AWS_CMD}" s3api list-object-versions \
    --bucket "${BUCKET}" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}, Quiet: `true`}' \
    --output json \
    2>/dev/null || echo '{}')"

if echo "${_markers_json}" | grep -q '"Key"'; then
    ("${_AWS_CMD}" s3api delete-objects \
        --bucket "${BUCKET}" \
        --delete "${_markers_json}" \
        2>/dev/null) || true
fi

# 3c. Delete the (now-empty) bucket
("${_AWS_CMD}" s3api delete-bucket \
    --bucket "${BUCKET}" \
    --region us-east-1 \
    2>/dev/null) || true

# ── 4. CloudWatch log group ───────────────────────────────────────────────────
("${_AWS_CMD}" logs delete-log-group \
    --log-group-name "${LOG_GROUP}" \
    --region us-east-1 \
    2>/dev/null) || true

echo "Teardown complete."
