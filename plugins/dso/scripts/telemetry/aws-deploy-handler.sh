#!/usr/bin/env bash
# aws-deploy-handler.sh (${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/) — DSO telemetry Lambda deploy
set -euo pipefail
#
# Packages and deploys the Lambda handler code (schema.py + validator.py + privacy.py +
# s3_writer.py + handler.py) to the provisioned Lambda function.
#
# ── Prerequisites ──────────────────────────────────────────────────────────────
#   Lambda function must already be provisioned (aws-setup-lambda.sh / story d94e).
#   S3 bucket must already be provisioned (aws-setup-bucket.sh / story 9720).
#
# ── Exit codes ─────────────────────────────────────────────────────────────────
#   0  = deploy successful
#   1  = unexpected error
#   2  = Lambda function not found (run aws-setup-lambda.sh first)
#   3  = S3 bucket not found (run aws-setup-bucket.sh first)
#
# ── Environment overrides (for testability) ────────────────────────────────────
#   LAMBDA_FUNCTION_NAME  Override Lambda function name (skips config lookup)
#   BUCKET_NAME           Override S3 bucket name (skips config lookup)
#   DSO_AWS_CMD           Override the aws binary (for PATH-stub tests)
#   DSO_READ_CONFIG_CMD   Override the path to the read-config helper

# ── Constants ──────────────────────────────────────────────────────────────────
readonly LAMBDA_REGION="us-east-1"

# ── Resolve paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Derive REPO_ROOT via git (preferred per test-plugin-scripts-no-relative-paths
# policy). PROJECT_ROOT env override keeps tests / unusual contexts working.
REPO_ROOT="${PROJECT_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")}"

# ── Overridable commands ───────────────────────────────────────────────────────
_AWS_CMD="${DSO_AWS_CMD:-aws}"
_READ_CONFIG_CMD="${DSO_READ_CONFIG_CMD:-"$REPO_ROOT/.claude/scripts/dso read-config"}"

# ── Read config ────────────────────────────────────────────────────────────────
_read_config() {
    $_READ_CONFIG_CMD "$1" 2>/dev/null || true
}

FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-$(_read_config review_telemetry.lambda_function_name)}"
BUCKET="${BUCKET_NAME:-$(_read_config review_telemetry.bucket_name)}"

if [[ -z "$FUNCTION_NAME" ]]; then
    echo "ERROR: review_telemetry.lambda_function_name not set in config and LAMBDA_FUNCTION_NAME not exported." >&2
    exit 1
fi

if [[ -z "$BUCKET" ]]; then
    echo "ERROR: review_telemetry.bucket_name not set in config and BUCKET_NAME not exported." >&2
    exit 1
fi

# ── Pre-flight: verify Lambda function exists ──────────────────────────────────
if ! "$_AWS_CMD" lambda get-function --function-name "$FUNCTION_NAME" --region "$LAMBDA_REGION" > /dev/null 2>&1; then
    echo "ERROR: Lambda function '$FUNCTION_NAME' not found. Run story d94e to provision it first." >&2
    exit 2
fi

# ── Pre-flight: verify S3 bucket exists ───────────────────────────────────────
if ! "$_AWS_CMD" s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
    echo "ERROR: S3 bucket '$BUCKET' not found. Run story 9720 to provision it first." >&2
    exit 3
fi

# ── Package handler files ──────────────────────────────────────────────────────
LAMBDA_DIR="$SCRIPT_DIR/lambda-handler"

ZIP_BASE=$(mktemp /tmp/handler-deploy.XXXXXX)
ZIP_PATH="${ZIP_BASE}.zip"
rm "$ZIP_BASE"

# Ensure cleanup on exit (success or failure)
# shellcheck disable=SC2064
trap "rm -f '$ZIP_PATH'" EXIT

(
    cd "$LAMBDA_DIR"
    zip -r "$ZIP_PATH" schema.py validator.py privacy.py s3_writer.py handler.py
)

# ── Deploy to Lambda ───────────────────────────────────────────────────────────
echo "Deploying handler to Lambda function: $FUNCTION_NAME"

"$_AWS_CMD" lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$ZIP_PATH" \
    --region "$LAMBDA_REGION"

# ── Wait for update to complete ────────────────────────────────────────────────
echo "Waiting for function update to complete..."
"$_AWS_CMD" lambda wait function-updated-v2 \
    --function-name "$FUNCTION_NAME" \
    --region "$LAMBDA_REGION"

echo "Deploy complete: $FUNCTION_NAME"
