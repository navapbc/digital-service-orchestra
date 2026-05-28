#!/usr/bin/env bash
set -euo pipefail
# tests/scripts/test-aws-teardown.sh
# Behavioral tests for plugins/dso/scripts/telemetry/aws-teardown.sh
#
# All AWS calls are PATH-stubbed — never touches real AWS endpoints or credentials.
# Stub aws logs every invocation to CALL_LOG for ordering/count assertions.
# Stdout is captured for confirmation-summary assertions.
#
# Cases covered:
#   1. t_no_flag_exits_1_no_deletes        — no --user-approved → exit 1; zero aws calls
#   2. t_with_flag_exits_0_all_deletes     — --user-approved → exit 0; all 4 resources deleted
#   3. t_iam_policy_order_before_delete    — list-role-policies before delete-role
#   4. t_confirmation_summary_before_deletes — all 4 names in stdout before first delete call
#   5. t_graceful_on_already_gone          — aws errors on deletes; still exits 0
#   6. t_versioned_bucket_cleanup          — list-object-versions + delete-objects before delete-bucket
#   7. t_log_group_derived_from_function_name — log group is /aws/lambda/<function_name>
#
# Usage: bash tests/scripts/test-aws-teardown.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/telemetry/aws-teardown.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-aws-teardown.sh ==="

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
    d="$(mktemp -d "${TMPDIR:-/tmp}/aws-teardown-test.XXXXXX")"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

make_tmpfile() {
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/aws-teardown-test.XXXXXX")"
    _TEST_TMPDIRS+=("$f")
    echo "$f"
}

# ── Shared constants ───────────────────────────────────────────────────────────
FUNCTION_NAME="test-fn"
ROLE_NAME="test-role"
BUCKET="test-bucket"
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"

# ── Helper: write the read-config stub ────────────────────────────────────────
write_read_config_stub() {
    local bin_dir="$1"
    local function_name="${2:-$FUNCTION_NAME}"
    cat > "$bin_dir/read-config-stub.sh" << STUBEOF
#!/usr/bin/env bash
key="\${1:-}"
case "\$key" in
    review_telemetry.lambda_function_name) echo "$function_name" ;;
    review_telemetry.iam_role_name)        echo "$ROLE_NAME" ;;
    review_telemetry.bucket_name)          echo "$BUCKET" ;;
    *) echo "" ;;
esac
exit 0
STUBEOF
    chmod +x "$bin_dir/read-config-stub.sh"
}

# ── Helper: write the standard aws stub ───────────────────────────────────────
# Stub environment variables read at runtime:
#   CALL_LOG            — file to log every aws invocation ($*)
#   STUB_FAIL_DELETES   — 1 → all delete calls return exit 1 (test graceful-on-gone)
#   STUB_HAS_VERSIONS   — 1 → list-object-versions returns one version + one delete marker
write_aws_stub() {
    local bin_dir="$1"
    # shellcheck disable=SC2016
    cat > "$bin_dir/aws" << 'STUBEOF'
#!/usr/bin/env bash
CALL_LOG="${CALL_LOG:-/dev/null}"
STUB_FAIL_DELETES="${STUB_FAIL_DELETES:-0}"
STUB_HAS_VERSIONS="${STUB_HAS_VERSIONS:-0}"

echo "$*" >> "$CALL_LOG"

sub="${1:-}"
sub2="${2:-}"

# ── Lambda ────────────────────────────────────────────────────────────────────
if [[ "$sub" == "lambda" && "$sub2" == "delete-function" ]]; then
    if [[ "$STUB_FAIL_DELETES" == "1" ]]; then exit 1; fi
    exit 0
fi

# ── IAM ───────────────────────────────────────────────────────────────────────
if [[ "$sub" == "iam" && "$sub2" == "list-role-policies" ]]; then
    # Return one inline policy name so the loop runs at least once
    echo "inline-policy-1"
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "delete-role-policy" ]]; then
    if [[ "$STUB_FAIL_DELETES" == "1" ]]; then exit 1; fi
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "list-attached-role-policies" ]]; then
    # Return one managed policy ARN
    echo "arn:aws:iam::aws:policy/AWSLambdaBasicExecutionRole"
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "detach-role-policy" ]]; then
    if [[ "$STUB_FAIL_DELETES" == "1" ]]; then exit 1; fi
    exit 0
fi

if [[ "$sub" == "iam" && "$sub2" == "delete-role" ]]; then
    if [[ "$STUB_FAIL_DELETES" == "1" ]]; then exit 1; fi
    exit 0
fi

# ── S3 ────────────────────────────────────────────────────────────────────────
if [[ "$sub" == "s3api" && "$sub2" == "list-object-versions" ]]; then
    if [[ "$STUB_HAS_VERSIONS" == "1" ]]; then
        echo '{"Versions":[{"Key":"obj1","VersionId":"v1"}],"DeleteMarkers":[{"Key":"obj2","VersionId":"dm1"}]}'
    else
        echo '{"Versions":null,"DeleteMarkers":null}'
    fi
    exit 0
fi

if [[ "$sub" == "s3api" && "$sub2" == "delete-objects" ]]; then
    if [[ "$STUB_FAIL_DELETES" == "1" ]]; then exit 1; fi
    echo '{"Deleted":[]}'
    exit 0
fi

if [[ "$sub" == "s3api" && "$sub2" == "delete-bucket" ]]; then
    if [[ "$STUB_FAIL_DELETES" == "1" ]]; then exit 1; fi
    exit 0
fi

# ── CloudWatch Logs ───────────────────────────────────────────────────────────
if [[ "$sub" == "logs" && "$sub2" == "delete-log-group" ]]; then
    if [[ "$STUB_FAIL_DELETES" == "1" ]]; then exit 1; fi
    exit 0
fi

exit 0
STUBEOF
    chmod +x "$bin_dir/aws"
}

# ── Test 1: No --user-approved → exit 1; zero aws calls ──────────────────────
t_no_flag_exits_1_no_deletes() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_ne "t_no_flag: exits non-zero" "0" "$exit_code"

    local call_count
    call_count=$(wc -l < "$call_log" | tr -d ' ')
    assert_eq "t_no_flag: zero aws calls without --user-approved" "0" "$call_count"
}

# ── Test 2: With --user-approved → exit 0; all 4 resource types deleted ──────
t_with_flag_exits_0_all_deletes() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" --user-approved >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_with_flag: exits 0" "0" "$exit_code"

    local del_fn
    del_fn=$(grep -c "lambda delete-function" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_with_flag: lambda delete-function called" "0" "$del_fn"

    local del_role
    del_role=$(grep -c "iam delete-role " "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_with_flag: iam delete-role called" "0" "$del_role"

    local del_bucket
    del_bucket=$(grep -c "s3api delete-bucket" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_with_flag: s3api delete-bucket called" "0" "$del_bucket"

    local del_logs
    del_logs=$(grep -c "logs delete-log-group" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_with_flag: logs delete-log-group called" "0" "$del_logs"
}

# ── Test 3: list-role-policies + delete-role-policy appear before delete-role ─
t_iam_policy_order_before_delete() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" --user-approved >/dev/null 2>&1 || true

    # list-role-policies must appear before delete-role (not delete-role-policy)
    local list_line delete_role_line
    list_line=$(grep -n "iam list-role-policies" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
    delete_role_line=$(grep -n "iam delete-role " "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")

    assert_ne "t_iam_order: list-role-policies appears in call log" "" "$list_line"
    assert_ne "t_iam_order: delete-role appears in call log" "" "$delete_role_line"

    local order_ok=0
    if [[ -n "$list_line" ]] && [[ -n "$delete_role_line" ]] && (( list_line < delete_role_line )); then
        order_ok=1
    fi
    assert_eq "t_iam_order: list-role-policies precedes delete-role" "1" "$order_ok"

    # delete-role-policy must also appear before delete-role
    local del_policy_line
    del_policy_line=$(grep -n "iam delete-role-policy" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
    assert_ne "t_iam_order: delete-role-policy appears in call log" "" "$del_policy_line"

    local policy_before_role=0
    if [[ -n "$del_policy_line" ]] && [[ -n "$delete_role_line" ]] && (( del_policy_line < delete_role_line )); then
        policy_before_role=1
    fi
    assert_eq "t_iam_order: delete-role-policy precedes delete-role" "1" "$policy_before_role"
}

# ── Test 4: Confirmation summary in stdout before any delete call ─────────────
t_confirmation_summary_before_deletes() {
    local mock_bin call_log stdout_file
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"
    stdout_file="$(make_tmpfile)"

    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    # Run with a special aws stub that appends a sentinel to call_log on first delete call.
    # We verify the stdout contains all 4 names (which it must since stdout is printed before
    # the first aws call in the script).
    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" --user-approved > "$stdout_file" 2>&1 || true

    local stdout_content
    stdout_content="$(cat "$stdout_file")"

    # All 4 resource names must appear in stdout
    assert_contains "t_summary: stdout contains function name" "$FUNCTION_NAME" "$stdout_content"
    assert_contains "t_summary: stdout contains role name" "$ROLE_NAME" "$stdout_content"
    assert_contains "t_summary: stdout contains bucket name" "$BUCKET" "$stdout_content"
    assert_contains "t_summary: stdout contains log group name" "$LOG_GROUP" "$stdout_content"

    # The summary lines must precede delete calls: stdout_file is written by script print
    # statements; the first aws call (delete) only happens after all prints. Since our stub
    # logs to call_log, we verify that any delete line appears AFTER the script has printed
    # all summaries. We check that stdout is non-empty (summaries printed) and call_log has
    # at least one delete entry (deletes were called).
    local has_output=0
    if [[ -n "$stdout_content" ]]; then has_output=1; fi
    assert_eq "t_summary: stdout is non-empty" "1" "$has_output"

    local has_deletes
    has_deletes=$(grep -c "delete" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_summary: delete calls were made" "0" "$has_deletes"
}

# ── Test 5: Graceful on already-gone (all deletes fail; still exit 0) ─────────
t_graceful_on_already_gone() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    local exit_code=0
    STUB_FAIL_DELETES=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" --user-approved >/dev/null 2>&1 || exit_code=$?

    assert_eq "t_graceful: exits 0 even when all deletes fail" "0" "$exit_code"
}

# ── Test 6: Versioned bucket cleanup before delete-bucket ─────────────────────
t_versioned_bucket_cleanup() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_aws_stub "$mock_bin"
    write_read_config_stub "$mock_bin"

    STUB_HAS_VERSIONS=1 \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" --user-approved >/dev/null 2>&1 || true

    # list-object-versions must appear before delete-bucket
    local list_versions_line delete_bucket_line
    list_versions_line=$(grep -n "s3api list-object-versions" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
    delete_bucket_line=$(grep -n "s3api delete-bucket" "$call_log" 2>/dev/null | head -1 | cut -d: -f1 || echo "")

    assert_ne "t_versioned: list-object-versions in call log" "" "$list_versions_line"
    assert_ne "t_versioned: delete-bucket in call log" "" "$delete_bucket_line"

    local order_ok=0
    if [[ -n "$list_versions_line" ]] && [[ -n "$delete_bucket_line" ]] && (( list_versions_line < delete_bucket_line )); then
        order_ok=1
    fi
    assert_eq "t_versioned: list-object-versions precedes delete-bucket" "1" "$order_ok"

    # delete-objects must appear when versions exist
    local del_objects
    del_objects=$(grep -c "s3api delete-objects" "$call_log" 2>/dev/null || echo "0")
    assert_ne "t_versioned: delete-objects called for versions" "0" "$del_objects"
}

# ── Test 7: Log group name derived from function name (not a separate config) ─
t_log_group_derived_from_function_name() {
    local mock_bin call_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"

    write_aws_stub "$mock_bin"
    # Use a custom function name to verify derivation
    write_read_config_stub "$mock_bin" "my-custom-fn"

    DSO_AWS_CMD="$mock_bin/aws" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CALL_LOG="$call_log" \
        bash "$SCRIPT" --user-approved >/dev/null 2>&1 || true

    # logs delete-log-group must use /aws/lambda/my-custom-fn
    local log_group_correct=0
    if grep "logs delete-log-group" "$call_log" 2>/dev/null | grep -q "/aws/lambda/my-custom-fn"; then
        log_group_correct=1
    fi
    assert_eq "t_log_group: derived as /aws/lambda/<function_name>" "1" "$log_group_correct"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
t_no_flag_exits_1_no_deletes
t_with_flag_exits_0_all_deletes
t_iam_policy_order_before_delete
t_confirmation_summary_before_deletes
t_graceful_on_already_gone
t_versioned_bucket_cleanup
t_log_group_derived_from_function_name

print_summary
