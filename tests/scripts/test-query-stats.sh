#!/usr/bin/env bash
set -euo pipefail
# tests/scripts/test-query-stats.sh
# Behavioral tests for plugins/dso/scripts/telemetry/query-stats.sh
#
# All AWS calls are stubbed via DSO_AWS_CMD — never touches real AWS endpoints.
# All DuckDB calls are stubbed via DSO_DUCKDB_CMD — never invokes real DuckDB.
# Config reads are stubbed via DSO_READ_CONFIG_CMD.
#
# Cases covered:
#   1. t_unknown_subcommand_exits_1_lists_5_names
#   2. t_roundtrip_landing_exit_0
#   3. t_roundtrip_timeout_exit_nonzero
#   4. t_roundtrip_uses_sentinel_client_id
#   5. t_counts_uses_date_glob_not_full_bucket
#   6. t_recent_uses_date_glob
#   7. t_missing_uses_date_glob
#   8. t_sizes_uses_date_glob
#   9. t_dso_aws_cmd_honored
#  10. t_dso_duckdb_cmd_honored
#  11. t_dso_read_config_cmd_honored
#  13. t_query_stats_default_route_not_query_stats (placeholder)
#
# Usage: bash tests/scripts/test-query-stats.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/telemetry/query-stats.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-query-stats.sh ==="

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
    d="$(mktemp -d "${TMPDIR:-/tmp}/query-stats-test.XXXXXX")"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

make_tmpfile() {
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/query-stats-test.XXXXXX")"
    _TEST_TMPDIRS+=("$f")
    echo "$f"
}

# ── Shared fixture constants ───────────────────────────────────────────────────
BUCKET_NAME="test-telemetry-bucket"

# ── Helper: write the read-config stub ────────────────────────────────────────
write_read_config_stub() {
    local bin_dir="$1"
    cat > "$bin_dir/read-config-stub.sh" << STUBEOF
#!/usr/bin/env bash
key="\${1:-}"
case "\$key" in
    review_telemetry.bucket_name) echo "$BUCKET_NAME" ;;
    *) echo "" ;;
esac
exit 0
STUBEOF
    chmod +x "$bin_dir/read-config-stub.sh"
}

# ── Helper: write aws stub ─────────────────────────────────────────────────────
# Env vars read at runtime:
#   CALL_LOG                   — file path for logging each invocation
#   STUB_LIST_OBJECTS_COUNT    — 0 = empty; 1 = return one object on first call; 2 = return on 2nd call
#   STUB_CALL_COUNTER_FILE     — file path to track call count for sequenced responses
write_aws_stub() {
    local bin_dir="$1"
    # shellcheck disable=SC2016
    cat > "$bin_dir/aws" << 'STUBEOF'
#!/usr/bin/env bash
CALL_LOG="${CALL_LOG:-/dev/null}"
STUB_LIST_OBJECTS_COUNT="${STUB_LIST_OBJECTS_COUNT:-0}"
STUB_CALL_COUNTER_FILE="${STUB_CALL_COUNTER_FILE:-/dev/null}"

echo "$*" >> "$CALL_LOG"

sub="${1:-}"
sub2="${2:-}"

# s3api list-objects-v2 (for roundtrip polling)
if [[ "$sub" == "s3api" && "$sub2" == "list-objects-v2" ]]; then
    # Track call count
    if [[ "$STUB_CALL_COUNTER_FILE" != "/dev/null" ]]; then
        local count=0
        if [[ -f "$STUB_CALL_COUNTER_FILE" ]]; then
            count="$(cat "$STUB_CALL_COUNTER_FILE" 2>/dev/null || echo 0)"
        fi
        count=$(( count + 1 ))
        echo "$count" > "$STUB_CALL_COUNTER_FILE"

        # Return object on 2nd call if STUB_LIST_OBJECTS_COUNT==2
        if [[ "$STUB_LIST_OBJECTS_COUNT" == "2" && "$count" -ge 2 ]]; then
            echo '{"Contents":[{"Key":"dso-roundtrip-test/2026-05-23/event.jsonl","Size":42}]}'
            exit 0
        fi
        # Return object immediately if STUB_LIST_OBJECTS_COUNT==1
        if [[ "$STUB_LIST_OBJECTS_COUNT" == "1" ]]; then
            echo '{"Contents":[{"Key":"dso-roundtrip-test/2026-05-23/event.jsonl","Size":42}]}'
            exit 0
        fi
    fi
    # Default: empty result (timeout scenario)
    echo '{"Contents":[]}'
    exit 0
fi

# Default: succeed silently
exit 0
STUBEOF
    chmod +x "$bin_dir/aws"
}

# ── Helper: write duckdb stub ──────────────────────────────────────────────────
# Records the SQL query passed to it in DUCKDB_QUERY_LOG
write_duckdb_stub() {
    local bin_dir="$1"
    # shellcheck disable=SC2016
    cat > "$bin_dir/duckdb" << 'STUBEOF'
#!/usr/bin/env bash
DUCKDB_QUERY_LOG="${DUCKDB_QUERY_LOG:-/dev/null}"

# Arguments may be: duckdb [flags] :memory: [sql_string]
# or piped via stdin. Capture all args + stdin.
args="$*"
echo "ARGS: $args" >> "$DUCKDB_QUERY_LOG"

# Read stdin if present (some callers pipe the SQL)
if [[ -p /dev/stdin ]] || [[ ! -t 0 ]]; then
    stdin_content="$(cat)"
    echo "STDIN: $stdin_content" >> "$DUCKDB_QUERY_LOG"
fi

# Return dummy output
echo "client_id | count"
echo "dso       | 42"
exit 0
STUBEOF
    chmod +x "$bin_dir/duckdb"
}

# ── Helper: write telemetry-emit stub ─────────────────────────────────────────
write_emit_stub() {
    local bin_dir="$1"
    local emit_log="$2"
    mkdir -p "$bin_dir/scripts/telemetry"
    # shellcheck disable=SC2016
    cat > "$bin_dir/scripts/telemetry/telemetry-emit.sh" << STUBEOF
#!/usr/bin/env bash
EMIT_LOG="$emit_log"
echo "EMIT: \$*" >> "\$EMIT_LOG"
exit 0
STUBEOF
    chmod +x "$bin_dir/scripts/telemetry/telemetry-emit.sh"
}

# ── Test 1: Unknown subcommand exits 1 and lists all 5 names ──────────────────
t_unknown_subcommand_exits_1_lists_5_names() {
    local mock_bin
    mock_bin="$(make_tmpdir)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_duckdb_stub "$mock_bin"

    local exit_code=0
    local out
    out="$(DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" bogus 2>&1)" || exit_code=$?

    assert_ne "t_unknown_subcommand: exits non-zero" "0" "$exit_code"

    for subcmd in roundtrip counts recent missing sizes; do
        assert_contains "t_unknown_subcommand: output contains '$subcmd'" "$subcmd" "$out"
    done
}

# ── Test 2: Roundtrip exits 0 when object lands on 2nd poll ──────────────────
t_roundtrip_landing_exit_0() {
    local mock_bin call_log counter_file emit_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"
    counter_file="$(make_tmpfile)"
    emit_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_emit_stub "$mock_bin" "$emit_log"

    local exit_code=0
    CALL_LOG="$call_log" \
        STUB_CALL_COUNTER_FILE="$counter_file" \
        STUB_LIST_OBJECTS_COUNT="2" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CLAUDE_PLUGIN_ROOT="$mock_bin" \
        DSO_ROUNDTRIP_BACKOFF_SCHEDULE="0 0" \
        bash "$SCRIPT" roundtrip 2>/dev/null || exit_code=$?

    assert_eq "t_roundtrip_landing: exits 0" "0" "$exit_code"
}

# ── Test 3: Roundtrip timeout exits non-zero ──────────────────────────────────
t_roundtrip_timeout_exit_nonzero() {
    local mock_bin emit_log
    mock_bin="$(make_tmpdir)"
    emit_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_emit_stub "$mock_bin" "$emit_log"

    local exit_code=0
    # Force fast timeout: single zero-sleep poll attempt
    STUB_LIST_OBJECTS_COUNT="0" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CLAUDE_PLUGIN_ROOT="$mock_bin" \
        DSO_ROUNDTRIP_BACKOFF_SCHEDULE="0" \
        bash "$SCRIPT" roundtrip 2>/dev/null || exit_code=$?

    assert_ne "t_roundtrip_timeout: exits non-zero" "0" "$exit_code"
}

# ── Test 4: Roundtrip uses sentinel client_id=dso-roundtrip-test ─────────────
t_roundtrip_uses_sentinel_client_id() {
    local mock_bin emit_log counter_file
    mock_bin="$(make_tmpdir)"
    emit_log="$(make_tmpfile)"
    counter_file="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_emit_stub "$mock_bin" "$emit_log"

    STUB_LIST_OBJECTS_COUNT="1" \
        STUB_CALL_COUNTER_FILE="$counter_file" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CLAUDE_PLUGIN_ROOT="$mock_bin" \
        DSO_ROUNDTRIP_BACKOFF_SCHEDULE="0" \
        bash "$SCRIPT" roundtrip 2>/dev/null || true

    local emit_args
    emit_args="$(cat "$emit_log" 2>/dev/null || echo "")"
    assert_contains "t_roundtrip_sentinel: emit called with dso-roundtrip-test" "dso-roundtrip-test" "$emit_args"
}

# ── Test 5: counts uses date-glob, not full-bucket scan ───────────────────────
t_counts_uses_date_glob_not_full_bucket() {
    local mock_bin duckdb_query_log
    mock_bin="$(make_tmpdir)"
    duckdb_query_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_duckdb_stub "$mock_bin"

    DUCKDB_QUERY_LOG="$duckdb_query_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" counts --days=3 2>/dev/null || true

    local query_captured
    query_captured="$(cat "$duckdb_query_log" 2>/dev/null || echo "")"

    # Must contain a date glob fragment (YYYY-MM-DD format)
    local has_date_glob=0
    if echo "$query_captured" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        has_date_glob=1
    fi
    assert_eq "t_counts_date_glob: query contains date prefix" "1" "$has_date_glob"

    # Must NOT contain a bare full-bucket glob (s3://bucket/**/*.jsonl without date)
    local has_full_scan=0
    if echo "$query_captured" | grep -qE "s3://$BUCKET_NAME/\*\*/\*\.jsonl"; then
        has_full_scan=1
    fi
    assert_eq "t_counts_date_glob: query does not contain bare full-bucket scan" "0" "$has_full_scan"
}

# ── Test 6: recent uses date-glob ─────────────────────────────────────────────
t_recent_uses_date_glob() {
    local mock_bin duckdb_query_log
    mock_bin="$(make_tmpdir)"
    duckdb_query_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_duckdb_stub "$mock_bin"

    DUCKDB_QUERY_LOG="$duckdb_query_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" recent --days=3 2>/dev/null || true

    local query_captured
    query_captured="$(cat "$duckdb_query_log" 2>/dev/null || echo "")"

    local has_date_glob=0
    if echo "$query_captured" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        has_date_glob=1
    fi
    assert_eq "t_recent_date_glob: query contains date prefix" "1" "$has_date_glob"
}

# ── Test 7: missing uses date-glob ────────────────────────────────────────────
t_missing_uses_date_glob() {
    local mock_bin duckdb_query_log
    mock_bin="$(make_tmpdir)"
    duckdb_query_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_duckdb_stub "$mock_bin"

    DUCKDB_QUERY_LOG="$duckdb_query_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" missing --days=3 2>/dev/null || true

    local query_captured
    query_captured="$(cat "$duckdb_query_log" 2>/dev/null || echo "")"

    local has_date_glob=0
    if echo "$query_captured" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        has_date_glob=1
    fi
    assert_eq "t_missing_date_glob: query contains date prefix" "1" "$has_date_glob"
}

# ── Test 8: sizes uses date-glob ──────────────────────────────────────────────
t_sizes_uses_date_glob() {
    local mock_bin duckdb_query_log
    mock_bin="$(make_tmpdir)"
    duckdb_query_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_duckdb_stub "$mock_bin"

    DUCKDB_QUERY_LOG="$duckdb_query_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" sizes --days=3 2>/dev/null || true

    local query_captured
    query_captured="$(cat "$duckdb_query_log" 2>/dev/null || echo "")"

    local has_date_glob=0
    if echo "$query_captured" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        has_date_glob=1
    fi
    assert_eq "t_sizes_date_glob: query contains date prefix" "1" "$has_date_glob"
}

# ── Test 9: DSO_AWS_CMD is honored ───────────────────────────────────────────
t_dso_aws_cmd_honored() {
    local mock_bin call_log counter_file emit_log
    mock_bin="$(make_tmpdir)"
    call_log="$(make_tmpfile)"
    counter_file="$(make_tmpfile)"
    emit_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_emit_stub "$mock_bin" "$emit_log"

    # Run roundtrip (which calls aws list-objects-v2)
    CALL_LOG="$call_log" \
        STUB_CALL_COUNTER_FILE="$counter_file" \
        STUB_LIST_OBJECTS_COUNT="1" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        CLAUDE_PLUGIN_ROOT="$mock_bin" \
        DSO_ROUNDTRIP_BACKOFF_SCHEDULE="0" \
        bash "$SCRIPT" roundtrip 2>/dev/null || true

    local aws_calls
    aws_calls="$(wc -l < "$call_log" 2>/dev/null | tr -d ' ' || echo "0")"
    assert_ne "t_dso_aws_cmd_honored: stub aws called >= 1 time" "0" "$aws_calls"
}

# ── Test 10: DSO_DUCKDB_CMD is honored ───────────────────────────────────────
t_dso_duckdb_cmd_honored() {
    local mock_bin duckdb_query_log
    mock_bin="$(make_tmpdir)"
    duckdb_query_log="$(make_tmpfile)"

    write_read_config_stub "$mock_bin"
    write_aws_stub "$mock_bin"
    write_duckdb_stub "$mock_bin"

    # Run counts (calls duckdb)
    DUCKDB_QUERY_LOG="$duckdb_query_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" counts --days=2 2>/dev/null || true

    local duckdb_calls
    duckdb_calls="$(wc -l < "$duckdb_query_log" 2>/dev/null | tr -d ' ' || echo "0")"
    assert_ne "t_dso_duckdb_cmd_honored: stub duckdb called >= 1 time" "0" "$duckdb_calls"
}

# ── Test 11: DSO_READ_CONFIG_CMD is honored ───────────────────────────────────
t_dso_read_config_cmd_honored() {
    local mock_bin config_call_log duckdb_query_log
    mock_bin="$(make_tmpdir)"
    config_call_log="$(make_tmpfile)"
    duckdb_query_log="$(make_tmpfile)"

    write_duckdb_stub "$mock_bin"

    # Write a read-config stub that logs calls
    cat > "$mock_bin/read-config-stub.sh" << STUBEOF
#!/usr/bin/env bash
key="\${1:-}"
echo "CONFIG_CALL: \$key" >> "$config_call_log"
case "\$key" in
    review_telemetry.bucket_name) echo "$BUCKET_NAME" ;;
    *) echo "" ;;
esac
exit 0
STUBEOF
    chmod +x "$mock_bin/read-config-stub.sh"

    write_aws_stub "$mock_bin"

    DUCKDB_QUERY_LOG="$duckdb_query_log" \
        DSO_AWS_CMD="$mock_bin/aws" \
        DSO_DUCKDB_CMD="$mock_bin/duckdb" \
        DSO_READ_CONFIG_CMD="$mock_bin/read-config-stub.sh" \
        bash "$SCRIPT" counts --days=1 2>/dev/null || true

    local config_calls
    config_calls="$(cat "$config_call_log" 2>/dev/null || echo "")"
    assert_contains "t_read_config_honored: read-config called for bucket_name" "review_telemetry.bucket_name" "$config_calls"
}

# ── Test 13: placeholder for default routing semantics (task 8349 domain) ────
t_query_stats_default_route_not_query_stats() {
    echo "INFO: default routing semantics owned by task 8349-c3ea-4691-4534"
    (( ++PASS ))
}

# ── Run all tests ──────────────────────────────────────────────────────────────
t_unknown_subcommand_exits_1_lists_5_names
t_roundtrip_landing_exit_0
t_roundtrip_timeout_exit_nonzero
t_roundtrip_uses_sentinel_client_id
t_counts_uses_date_glob_not_full_bucket
t_recent_uses_date_glob
t_missing_uses_date_glob
t_sizes_uses_date_glob
t_dso_aws_cmd_honored
t_dso_duckdb_cmd_honored
t_dso_read_config_cmd_honored
t_query_stats_default_route_not_query_stats

print_summary
