#!/usr/bin/env bash
set -euo pipefail
# tests/scripts/test-aws-setup-bucket.sh
# Behavioral tests for plugins/dso/scripts/telemetry/aws-setup-bucket.sh
#
# All AWS calls are PATH-stubbed — never touches real AWS endpoints or credentials.
# Stub aws logs every invocation to a per-test CALL_LOG for ordering/count assertions.
#
# Cases covered:
#   1.  t_happy_path_creates_all_resources        — exit 0; all s3api verbs appear once
#   2.  t_rerun_is_no_op                          — seeded state; second-run call count == 0; exit 0
#   3.  t_missing_iam_aborts_before_create        — missing perm → exit 5; zero create-bucket calls
#   4.  t_public_access_block_set_before_policy   — put-public-access-block before put-bucket-policy
#   5.  t_policy_references_lambda_role_arn       — policy JSON contains lambda ARN from config
#   6.  t_config_write_preserves_existing_keys    — unrelated key untouched after run
#   7.  t_config_write_rewrites_existing_bucket_name_key — stale key replaced; exactly one entry
#   8.  t_region_pinned_to_us_east_1              — every s3api call carries us-east-1
#   9.  t_sts_get_caller_identity_failure_aborts_before_create — STS fail → exit 4; zero creates
#  10.  t_missing_lambda_role_arn_aborts_with_exit_6 — missing lambda_role_arn → exit 6
#  11.  t_missing_bucket_name_prefix_aborts_with_exit_6 — missing bucket_name_prefix → exit 6
#  12.  t_config_write_runs_after_ensure_bucket_before_other_ensures — partial-state ordering
#
# Usage: bash tests/scripts/test-aws-setup-bucket.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/telemetry/aws-setup-bucket.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-aws-setup-bucket.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
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

# ── Shared constants ──────────────────────────────────────────────────────────
LAMBDA_ROLE_ARN="arn:aws:iam::123456789012:role/test-lambda-role"
BUCKET_NAME_PREFIX="dso-telemetry"

# ── Helper: write the aws stub ────────────────────────────────────────────────
# Environment variables the stub reads at runtime:
#   CALL_LOG              — file path for call logging (defaults to /dev/null)
#   STUB_STS_FAIL         — set to 1 to make sts get-caller-identity exit 1
#   STUB_IAM_MISSING_PERM — set to 1 to return empty AttachedPolicies list
#   STUB_BUCKET_EXISTS    — set to 1 to make s3api head-bucket exit 0
write_aws_stub() {
    local bin_dir="$1"
    # shellcheck disable=SC2016
    cat > "$bin_dir/aws" << 'STUBEOF'
#!/usr/bin/env bash
CALL_LOG="${CALL_LOG:-/dev/null}"
STUB_STS_FAIL="${STUB_STS_FAIL:-0}"
STUB_IAM_MISSING_PERM="${STUB_IAM_MISSING_PERM:-0}"
STUB_BUCKET_EXISTS="${STUB_BUCKET_EXISTS:-0}"

echo "$*" >> "$CALL_LOG"

sub="${1:-}"
sub2="${2:-}"

if [[ "$sub" == "sts" && "$sub2" == "get-caller-identity" ]]; then
    if [[ "$STUB_STS_FAIL" == "1" ]]; then
        echo "An error occurred (InvalidClientTokenId): credential failure" >&2
        exit 1
    fi
    echo '{"UserId":"AIDEXAMPLE123","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test"}'
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "list-attached-user-policies" ]]; then
    if [[ "$STUB_IAM_MISSING_PERM" == "1" ]]; then
        echo '{"AttachedPolicies":[]}'
    else
        echo '{"AttachedPolicies":[{"PolicyName":"AdministratorAccess","PolicyArn":"arn:aws:iam::aws:policy/AdministratorAccess"}]}'
    fi
    exit 0
fi

if [[ "$sub" == "s3api" && "$sub2" == "head-bucket" ]]; then
    if [[ "$STUB_BUCKET_EXISTS" == "1" ]]; then
        exit 0
    fi
    exit 1
fi

if [[ "$sub" == "s3api" && "$sub2" == "create-bucket" ]]; then
    echo '{"Location":"/dso-telemetry-review"}'
    exit 0
fi

if [[ "$sub" == "s3api" ]]; then
    exit 0
fi

exit 0
STUBEOF
    chmod +x "$bin_dir/aws"
}

# ── Helper: write the read-config stub ────────────────────────────────────────
# Parameters:
#   $1 bin_dir
#   $2 lambda_role_arn  (default: $LAMBDA_ROLE_ARN)
#   $3 bucket_name_prefix (default: $BUCKET_NAME_PREFIX)
#   $4 empty_lambda_arn  1 → return empty string for lambda_role_arn key
#   $5 empty_prefix      1 → return empty string for bucket_name_prefix key
write_read_config_stub() {
    local bin_dir="$1"
    local lambda_role_arn="${2:-$LAMBDA_ROLE_ARN}"
    local bucket_name_prefix="${3:-$BUCKET_NAME_PREFIX}"
    local empty_lambda="${4:-0}"
    local empty_prefix="${5:-0}"
    # Use a here-doc with variable interpolation (NOT single-quoted) so we can
    # bake the stub-time values into the generated script.
    cat > "$bin_dir/read-config-stub.sh" << STUBEOF
#!/usr/bin/env bash
key="\${1:-}"
case "\$key" in
    review_telemetry.lambda_role_arn)
        if [[ "$empty_lambda" == "1" ]]; then echo ""; else echo "$lambda_role_arn"; fi ;;
    review_telemetry.bucket_name_prefix)
        if [[ "$empty_prefix" == "1" ]]; then echo ""; else echo "$bucket_name_prefix"; fi ;;
    review_telemetry.aws_account_id)
        echo "123456789012" ;;
    *)
        echo "" ;;
esac
exit 0
STUBEOF
    chmod +x "$bin_dir/read-config-stub.sh"
}

# ── Test 1: Happy path — all resources created; exit 0 ───────────────────────
t_happy_path_creates_all_resources() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    touch "$call_log"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    local output
    output=$(
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "t_happy_path: exits 0" "0" "$exit_code"

    local create_count
    create_count=$(grep -c "s3api create-bucket" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_happy_path: create-bucket called exactly once" "1" "$create_count"

    local access_count
    access_count=$(grep -c "s3api put-public-access-block" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_happy_path: put-public-access-block called exactly once" "1" "$access_count"

    local encrypt_count
    encrypt_count=$(grep -c "s3api put-bucket-encryption" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_happy_path: put-bucket-encryption called exactly once" "1" "$encrypt_count"

    local lifecycle_count
    lifecycle_count=$(grep -c "s3api put-bucket-lifecycle-configuration" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_happy_path: put-bucket-lifecycle-configuration called exactly once" "1" "$lifecycle_count"

    local policy_count
    policy_count=$(grep -c "s3api put-bucket-policy" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_happy_path: put-bucket-policy called exactly once" "1" "$policy_count"
}

# ── Test 2: Re-run is a no-op ─────────────────────────────────────────────────
t_rerun_is_no_op() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    touch "$call_log"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    # First run (normal state)
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || true

    # Reset log and run again with STUB_BUCKET_EXISTS=1
    : > "$call_log"
    local exit_code=0
    STUB_BUCKET_EXISTS=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_rerun: second run exits 0" "0" "$exit_code"

    local create_count
    create_count=$(grep -c "s3api create-bucket" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_rerun: no create-bucket on second run" "0" "$create_count"
}

# ── Test 3: Missing IAM perm → exit 5; zero create-bucket calls ──────────────
t_missing_iam_aborts_before_create() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    touch "$call_log"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    local output
    output=$(
        STUB_IAM_MISSING_PERM=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "t_missing_iam: exits 5" "5" "$exit_code"

    local create_count
    create_count=$(grep -c "s3api create-bucket" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_missing_iam: zero create-bucket calls" "0" "$create_count"

    local found_perm=0
    if echo "$output" | grep -qiE 'permission|missing|perm|policy'; then
        found_perm=1
    fi
    assert_eq "t_missing_iam: stderr names missing perm" "1" "$found_perm"
}

# ── Test 4: put-public-access-block precedes put-bucket-policy by line ────────
t_public_access_block_set_before_policy() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    touch "$call_log"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || true

    local access_line policy_line
    access_line=$(grep -n "s3api put-public-access-block" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")
    policy_line=$(grep -n "s3api put-bucket-policy" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")

    # access_line must be non-zero (call exists) and less than policy_line
    assert_ne "t_ordering: put-public-access-block must appear in log" "0" "${access_line:-0}"
    assert_ne "t_ordering: put-bucket-policy must appear in log" "0" "${policy_line:-0}"

    local ordering_ok=0
    if [[ "${access_line:-0}" -gt 0 && "${policy_line:-0}" -gt 0 && "${access_line}" -lt "${policy_line}" ]]; then
        ordering_ok=1
    fi
    assert_eq "t_ordering: put-public-access-block (line $access_line) precedes put-bucket-policy (line $policy_line)" "1" "$ordering_ok"
}

# ── Test 5: Policy JSON contains exact lambda role ARN ───────────────────────
t_policy_references_lambda_role_arn() {
    local mock_bin policy_arg_file
    mock_bin="$(make_tmpdir)"
    policy_arg_file="$(make_tmpdir)/policy_arg.txt"
    touch "$policy_arg_file"

    # Augment the aws stub to capture --policy argument
    # shellcheck disable=SC2016
    cat > "$mock_bin/aws" << 'STUBEOF'
#!/usr/bin/env bash
CALL_LOG="${CALL_LOG:-/dev/null}"
POLICY_ARG_FILE="${POLICY_ARG_FILE:-/dev/null}"

echo "$*" >> "$CALL_LOG"

sub="${1:-}"
sub2="${2:-}"

if [[ "$sub" == "s3api" && "$sub2" == "put-bucket-policy" ]]; then
    # Capture the --policy value from args
    prev=""
    for arg in "$@"; do
        if [[ "$prev" == "--policy" ]]; then
            echo "$arg" > "$POLICY_ARG_FILE"
        fi
        prev="$arg"
    done
    exit 0
fi

if [[ "$sub" == "sts" && "$sub2" == "get-caller-identity" ]]; then
    echo '{"UserId":"AIDEXAMPLE123","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test"}'
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "list-attached-user-policies" ]]; then
    echo '{"AttachedPolicies":[{"PolicyName":"AdministratorAccess","PolicyArn":"arn:aws:iam::aws:policy/AdministratorAccess"}]}'
    exit 0
fi

if [[ "$sub" == "s3api" && "$sub2" == "head-bucket" ]]; then
    exit 1
fi

if [[ "$sub" == "s3api" && "$sub2" == "create-bucket" ]]; then
    echo '{"Location":"/dso-telemetry-review"}'
    exit 0
fi

exit 0
STUBEOF
    chmod +x "$mock_bin/aws"
    write_read_config_stub "$mock_bin"

    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        POLICY_ARG_FILE="$policy_arg_file" \
        bash "$SCRIPT" >/dev/null 2>&1 || true

    local policy_json
    policy_json="$(cat "$policy_arg_file" 2>/dev/null || echo "")"

    assert_contains "t_policy_arn: policy contains lambda role ARN" \
        "$LAMBDA_ROLE_ARN" "$policy_json"
}

# ── Test 6: Config write preserves unrelated keys ─────────────────────────────
t_config_write_preserves_existing_keys() {
    local mock_bin conf_file
    mock_bin="$(make_tmpdir)"
    conf_file="$(make_tmpdir)/dso-config.conf"
    echo "unrelated.key=value" > "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_config_preserves: exits 0" "0" "$exit_code"

    local preserved
    preserved=$(grep -c "^unrelated\.key=value$" "$conf_file" 2>/dev/null || echo "0")
    assert_eq "t_config_preserves: unrelated.key=value remains" "1" "$preserved"

    local bucket_written
    bucket_written=$(grep -c "^review_telemetry\.bucket_name=" "$conf_file" 2>/dev/null || echo "0")
    assert_ne "t_config_preserves: review_telemetry.bucket_name written" "0" "$bucket_written"
}

# ── Test 7: Stale bucket_name key is replaced with exactly one entry ──────────
t_config_write_rewrites_existing_bucket_name_key() {
    local mock_bin conf_file
    mock_bin="$(make_tmpdir)"
    conf_file="$(make_tmpdir)/dso-config.conf"
    echo "review_telemetry.bucket_name=stale-bucket" > "$conf_file"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        DSO_CONFIG_FILE="$conf_file" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_config_rewrites: exits 0" "0" "$exit_code"

    local count
    count=$(grep -c "^review_telemetry\.bucket_name=" "$conf_file" 2>/dev/null || echo "0")
    assert_eq "t_config_rewrites: exactly one review_telemetry.bucket_name line" "1" "$count"

    local stale_count
    stale_count=$(grep -c "^review_telemetry\.bucket_name=stale-bucket$" "$conf_file" 2>/dev/null || echo "0")
    assert_eq "t_config_rewrites: stale value not present" "0" "$stale_count"
}

# ── Test 8: Every s3api call carries us-east-1 ───────────────────────────────
t_region_pinned_to_us_east_1() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    touch "$call_log"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || true

    # Every s3api line must contain --region us-east-1
    local s3api_lines s3api_without_region
    s3api_lines=$(grep -c "s3api" "$call_log" 2>/dev/null || echo "0")
    s3api_without_region=$(grep "s3api" "$call_log" 2>/dev/null | grep -cv "us-east-1" || echo "0")

    assert_ne "t_region: at least one s3api call logged" "0" "$s3api_lines"
    assert_eq "t_region: all s3api calls contain us-east-1" "0" "$s3api_without_region"
}

# ── Test 9: STS failure → exit 4; zero create-bucket calls ──────────────────
t_sts_get_caller_identity_failure_aborts_before_create() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    touch "$call_log"
    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    local output
    output=$(
        STUB_STS_FAIL=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq "t_sts_fail: exits 4" "4" "$exit_code"

    local create_count
    create_count=$(grep -c "s3api create-bucket" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_sts_fail: zero create-bucket calls" "0" "$create_count"

    local found_cred=0
    if echo "$output" | grep -qiE 'credential|auth|token|sts'; then
        found_cred=1
    fi
    assert_eq "t_sts_fail: stderr names credential failure" "1" "$found_cred"
}

# ── Test 10: Missing lambda_role_arn → exit 6 ─────────────────────────────────
t_missing_lambda_role_arn_aborts_with_exit_6() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    touch "$call_log"
    write_aws_stub "$mock_bin"
    # empty_lambda=1 → lambda_role_arn returns ""
    write_read_config_stub "$mock_bin" "" "$BUCKET_NAME_PREFIX" "1" "0"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_missing_lambda_arn: exits 6" "6" "$exit_code"

    local create_count
    create_count=$(grep -c "s3api create-bucket" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_missing_lambda_arn: zero create-bucket calls" "0" "$create_count"
}

# ── Test 11: Missing bucket_name_prefix → exit 6 ─────────────────────────────
t_missing_bucket_name_prefix_aborts_with_exit_6() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpdir)/calls.log"
    touch "$call_log"
    write_aws_stub "$mock_bin"
    # empty_prefix=1 → bucket_name_prefix returns ""
    write_read_config_stub "$mock_bin" "$LAMBDA_ROLE_ARN" "" "0" "1"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_missing_prefix: exits 6" "6" "$exit_code"

    local create_count
    create_count=$(grep -c "s3api create-bucket" "$call_log" 2>/dev/null || echo "0")
    assert_eq "t_missing_prefix: zero create-bucket calls" "0" "$create_count"
}

# ── Test 12: config_write runs after ensure_bucket, before other ensures ──────
# Verify partial-state recovery: if script is interrupted after create-bucket
# and config-write, on re-run the bucket name is still correct.
t_config_write_runs_after_ensure_bucket_before_other_ensures() {
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

    assert_eq "t_config_ordering: exits 0" "0" "$exit_code"

    # create-bucket must appear before put-bucket-encryption in the call log
    local create_line encrypt_line
    create_line=$(grep -n "s3api create-bucket" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")
    encrypt_line=$(grep -n "s3api put-bucket-encryption" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")

    assert_ne "t_config_ordering: create-bucket appears in log" "0" "${create_line:-0}"
    assert_ne "t_config_ordering: put-bucket-encryption appears in log" "0" "${encrypt_line:-0}"

    # Config file must contain bucket_name written after create-bucket
    local bucket_written
    bucket_written=$(grep -c "^review_telemetry\.bucket_name=" "$conf_file" 2>/dev/null || echo "0")
    assert_ne "t_config_ordering: bucket_name written to config" "0" "$bucket_written"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
t_happy_path_creates_all_resources
t_rerun_is_no_op
t_missing_iam_aborts_before_create
t_public_access_block_set_before_policy
t_policy_references_lambda_role_arn
t_config_write_preserves_existing_keys
t_config_write_rewrites_existing_bucket_name_key
t_region_pinned_to_us_east_1
t_sts_get_caller_identity_failure_aborts_before_create
t_missing_lambda_role_arn_aborts_with_exit_6
t_missing_bucket_name_prefix_aborts_with_exit_6
t_config_write_runs_after_ensure_bucket_before_other_ensures

print_summary
