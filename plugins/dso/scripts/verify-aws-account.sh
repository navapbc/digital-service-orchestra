#!/usr/bin/env bash
# verify-aws-account.sh
#
# Asserts that the AWS account ID returned by `aws sts get-caller-identity`
# matches the expected account ID configured in dso-config.conf under the key
# `review_telemetry.aws_account_id` (default: 820258254566 when absent).
#
# ── Exit codes ────────────────────────────────────────────────────────────────
#   0  = account ID matches expected value (prints OK + account ID)
#   1  = account ID mismatch (prints expected vs. actual diagnostic)
#   2  = aws CLI absent from PATH (prints remediation hint)
#   3  = python3 absent from PATH (prints remediation hint)
#   4  = aws call failed (authentication error, network error, etc.)
#
# ── Environment overrides (for testability) ───────────────────────────────────
#   DSO_READ_CONFIG_CMD  Override the path to the read-config helper
#   DSO_AWS_CMD          Override the aws binary to use (for PATH-stub tests)

set -euo pipefail

# ── Resolve script directory and repo root ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ lives three levels below repo root (${CLAUDE_PLUGIN_ROOT}/scripts/)
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
_READ_CONFIG_CMD="${DSO_READ_CONFIG_CMD:-"$REPO_ROOT/.claude/scripts/dso read-config"}"
_AWS_CMD="${DSO_AWS_CMD:-aws}"

# ── Preflight: check for required binaries ────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found on PATH — required to parse aws CLI JSON output." >&2
    echo "Remediation: install Python 3.x (https://www.python.org/downloads/) and ensure it is on PATH." >&2
    exit 3
fi

if ! command -v aws >/dev/null 2>&1 && [[ "$_AWS_CMD" == "aws" ]]; then
    echo "ERROR: aws CLI not found on PATH — aws CLI is required to verify account identity." >&2
    echo "Remediation: install the AWS CLI (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and ensure it is on PATH." >&2
    exit 2
fi

# When DSO_AWS_CMD is a full path/stub, check it exists
if [[ "$_AWS_CMD" != "aws" ]] && ! command -v "$_AWS_CMD" >/dev/null 2>&1; then
    # Might be a direct path — check if executable
    if [[ ! -x "$_AWS_CMD" ]]; then
        echo "ERROR: aws CLI not found — '$_AWS_CMD' is not executable." >&2
        exit 2
    fi
fi

# ── Read expected account from config ─────────────────────────────────────────
_DEFAULT_ACCOUNT="820258254566"
EXPECTED_ACCOUNT="$($_READ_CONFIG_CMD review_telemetry.aws_account_id 2>/dev/null || true)"
if [[ -z "$EXPECTED_ACCOUNT" ]]; then
    EXPECTED_ACCOUNT="$_DEFAULT_ACCOUNT"
fi

# ── Invoke aws sts get-caller-identity ────────────────────────────────────────
_aws_raw=""
_aws_exit=0
_aws_raw="$("$_AWS_CMD" sts get-caller-identity --output json 2>&1)" || _aws_exit=$?

if [[ $_aws_exit -ne 0 ]]; then
    echo "ERROR: 'aws sts get-caller-identity' failed (exit $_aws_exit)." >&2
    echo "aws output: ${_aws_raw}" >&2
    echo "Remediation: ensure AWS credentials are configured (aws configure, AWS_PROFILE, or IAM role)." >&2
    exit 4
fi

# ── Parse Account field from JSON ─────────────────────────────────────────────
ACTUAL_ACCOUNT="$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    print(data['Account'])
except (KeyError, json.JSONDecodeError) as e:
    print('ERROR: failed to parse Account from aws output: ' + str(e), file=sys.stderr)
    sys.exit(1)
" "$_aws_raw")"

# ── Compare expected vs. actual ───────────────────────────────────────────────
if [[ "$ACTUAL_ACCOUNT" == "$EXPECTED_ACCOUNT" ]]; then
    echo "OK: AWS account ID verified: $ACTUAL_ACCOUNT"
    exit 0
else
    echo "ERROR: AWS account ID mismatch." >&2
    echo "  expected: $EXPECTED_ACCOUNT" >&2
    echo "  actual:   $ACTUAL_ACCOUNT" >&2
    echo "Remediation: check that the correct AWS profile/role is active, or update review_telemetry.aws_account_id in .claude/dso-config.conf." >&2
    exit 1
fi
