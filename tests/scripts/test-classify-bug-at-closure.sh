#!/usr/bin/env bash
# tests/scripts/test-classify-bug-at-closure.sh
# RED-phase tests for plugins/dso/scripts/classify-bug-at-closure.sh
#
# Behaviors under test:
#   1. test_script_exists           — target script file exists
#   2. test_skip_on_escalated       — "Escalated to user:" prefix → exit 0, no tag written
#   3. test_success_path_applies_tag — valid slug → TICKET_CMD called with "tag <id> bug-type-<slug>"
#   4. test_schema_failure_writes_fallback_tags — invalid slug → both uncategorized + classifier-failed-schema tags
#   5. test_uncategorized_output    — "uncategorized" slug → applies bug-type-uncategorized tag
#
# Usage: bash tests/scripts/test-classify-bug-at-closure.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/classify-bug-at-closure.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Global cleanup registry — each test appends its temp files/dirs here.
declare -a CLEANUP_PATHS=()
trap 'rm -rf "${CLEANUP_PATHS[@]:-}"' EXIT

# ── Helper: build a mock TICKET_CMD that logs its arguments ──────────────────

_make_mock_ticket_cmd() {
    local call_log mock_file mock_dir
    mock_dir=$(mktemp -d "${TMPDIR:-/tmp}/mock-ticket-XXXXXX")
    CLEANUP_PATHS+=("$mock_dir")
    call_log="$mock_dir/call.log"
    mock_file="$mock_dir/ticket-cmd"
    cat > "$mock_file" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "${CALL_LOG}"
MOCK_EOF
    chmod +x "$mock_file"
    # Expose both paths to callers
    MOCK_FILE="$mock_file"
    CALL_LOG="$call_log"
}

# ── Test 1: script exists ─────────────────────────────────────────────────────

test_script_exists() {
    if [[ -f "$SCRIPT" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_script_exists\n  expected: %s to exist\n  actual:   file not found\n" "$SCRIPT" >&2
    fi
}

test_script_exists

# ── Test 2: skip on "Escalated to user:" prefix ──────────────────────────────
# The script should exit 0 and NOT call TICKET_CMD with a 'tag' subcommand.

test_skip_on_escalated() {
    local MOCK_FILE CALL_LOG
    _make_mock_ticket_cmd

    local exit_code=0
    CALL_LOG="$CALL_LOG" \
        TICKET_CMD="$MOCK_FILE" \
        CLASSIFIER_OUTPUT="scope-drift" \
        bash "$SCRIPT" abc123 "Escalated to user:" 2>/dev/null || exit_code=$?

    assert_eq "test_skip_on_escalated: exits 0" "0" "$exit_code"

    # TICKET_CMD must NOT have been called with 'tag'
    local tag_calls=""
    if [[ -f "$CALL_LOG" ]]; then
        tag_calls=$(grep -c "^tag " "$CALL_LOG" 2>/dev/null || echo "0")
    else
        tag_calls="0"
    fi
    assert_eq "test_skip_on_escalated: no tag calls" "0" "$tag_calls"
}

test_skip_on_escalated

# ── Test 3: success path — valid slug applies tag ─────────────────────────────
# CLASSIFIER_OUTPUT=scope-drift → TICKET_CMD called with: tag abc123 bug-type-scope-drift

test_success_path_applies_tag() {
    local MOCK_FILE CALL_LOG
    _make_mock_ticket_cmd

    local exit_code=0
    CALL_LOG="$CALL_LOG" \
        TICKET_CMD="$MOCK_FILE" \
        CLASSIFIER_OUTPUT="scope-drift" \
        bash "$SCRIPT" abc123 "Fixed:" 2>/dev/null || exit_code=$?

    assert_eq "test_success_path_applies_tag: exits 0" "0" "$exit_code"

    local found_tag=0
    if [[ -f "$CALL_LOG" ]] && grep -qF "tag abc123 bug-type-scope-drift" "$CALL_LOG" 2>/dev/null; then
        found_tag=1
    fi
    assert_eq "test_success_path_applies_tag: tag abc123 bug-type-scope-drift called" "1" "$found_tag"
}

test_success_path_applies_tag

# ── Test 4: schema failure — writes both failure tags ─────────────────────────
# CLASSIFIER_OUTPUT=invalid-not-a-real-slug (not a valid enum slug)
# Script must:
#   - exit 0 (graceful, do not propagate failure)
#   - call TICKET_CMD with: tag abc123 bug-type-uncategorized
#   - call TICKET_CMD with: tag abc123 bug-type-classifier-failed-schema

test_schema_failure_writes_fallback_tags() {
    local MOCK_FILE CALL_LOG
    _make_mock_ticket_cmd

    local exit_code=0
    CALL_LOG="$CALL_LOG" \
        TICKET_CMD="$MOCK_FILE" \
        CLASSIFIER_OUTPUT="invalid-not-a-real-slug" \
        bash "$SCRIPT" abc123 "Fixed:" 2>/dev/null || exit_code=$?

    assert_eq "test_schema_failure_writes_fallback_tags: exits 0 (graceful)" "0" "$exit_code"

    local found_uncategorized=0
    if [[ -f "$CALL_LOG" ]] && grep -qF "tag abc123 bug-type-uncategorized" "$CALL_LOG" 2>/dev/null; then
        found_uncategorized=1
    fi
    assert_eq "test_schema_failure_writes_fallback_tags: bug-type-uncategorized tag written" "1" "$found_uncategorized"

    local found_classifier_failed=0
    if [[ -f "$CALL_LOG" ]] && grep -qF "tag abc123 bug-type-classifier-failed-schema" "$CALL_LOG" 2>/dev/null; then
        found_classifier_failed=1
    fi
    assert_eq "test_schema_failure_writes_fallback_tags: bug-type-classifier-failed-schema tag written" "1" "$found_classifier_failed"
}

test_schema_failure_writes_fallback_tags

# ── Test 5: uncategorized output — valid, applies tag as-is ──────────────────
# CLASSIFIER_OUTPUT=uncategorized → TICKET_CMD called with: tag abc123 bug-type-uncategorized

test_uncategorized_output() {
    local MOCK_FILE CALL_LOG
    _make_mock_ticket_cmd

    local exit_code=0
    CALL_LOG="$CALL_LOG" \
        TICKET_CMD="$MOCK_FILE" \
        CLASSIFIER_OUTPUT="uncategorized" \
        bash "$SCRIPT" abc123 "Fixed:" 2>/dev/null || exit_code=$?

    assert_eq "test_uncategorized_output: exits 0" "0" "$exit_code"

    local found_tag=0
    if [[ -f "$CALL_LOG" ]] && grep -qF "tag abc123 bug-type-uncategorized" "$CALL_LOG" 2>/dev/null; then
        found_tag=1
    fi
    assert_eq "test_uncategorized_output: tag abc123 bug-type-uncategorized called" "1" "$found_tag"
}

test_uncategorized_output

# ── Test 6: retry-once — first tag call fails, second succeeds ────────────────
# A mock that fails on the first 'tag' subcommand call and succeeds on the
# second (retry). The script must exit 0 and the tag must appear in the log
# exactly once (the successful retry call).

test_retry_on_first_tag_failure() {
    local mock_dir call_log count_file mock_file
    mock_dir=$(mktemp -d "${TMPDIR:-/tmp}/mock-retry-XXXXXX")
    CLEANUP_PATHS+=("$mock_dir")
    call_log="$mock_dir/call.log"
    count_file="$mock_dir/count"
    echo "0" > "$count_file"
    mock_file="$mock_dir/ticket-cmd"
    cat > "$mock_file" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$call_log"
case "\$1" in
    tag)
        cnt=\$(cat "$count_file" 2>/dev/null || echo 0)
        cnt=\$((cnt + 1))
        echo "\$cnt" > "$count_file"
        [ "\$cnt" -eq 1 ] && exit 1
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$mock_file"

    local exit_code=0
    TICKET_CMD="$mock_file" \
        CLASSIFIER_OUTPUT="scope-drift" \
        bash "$SCRIPT" abc123 "Fixed:" 2>/dev/null || exit_code=$?

    assert_eq "test_retry_on_first_tag_failure: exits 0 after retry" "0" "$exit_code"

    local tag_count
    tag_count=$(grep -c "^tag " "$call_log" 2>/dev/null || echo "0")
    assert_eq "test_retry_on_first_tag_failure: tag called twice (initial + retry)" "2" "$tag_count"
}

test_retry_on_first_tag_failure

# ── Test 7: comment-on-second-failure — both tag attempts fail ────────────────
# A mock where every 'tag' call exits 1. The script must exit 0, and it must
# have called TICKET_CMD with 'comment' (the comment-on-failure path).

test_comment_written_on_double_failure() {
    local mock_dir call_log mock_file
    mock_dir=$(mktemp -d "${TMPDIR:-/tmp}/mock-fail-XXXXXX")
    CLEANUP_PATHS+=("$mock_dir")
    call_log="$mock_dir/call.log"
    mock_file="$mock_dir/ticket-cmd"
    cat > "$mock_file" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$call_log"
case "\$1" in
    tag)     exit 1 ;;
    comment) exit 0 ;;
    *)       exit 0 ;;
esac
EOF
    chmod +x "$mock_file"

    local exit_code=0
    TICKET_CMD="$mock_file" \
        CLASSIFIER_OUTPUT="scope-drift" \
        bash "$SCRIPT" abc123 "Fixed:" 2>/dev/null || exit_code=$?

    assert_eq "test_comment_written_on_double_failure: exits 0 (graceful)" "0" "$exit_code"

    local comment_count
    comment_count=$(grep -c "^comment " "$call_log" 2>/dev/null || echo "0")
    assert_eq "test_comment_written_on_double_failure: ticket comment written after double tag failure" \
        "1" "$comment_count"
}

test_comment_written_on_double_failure

print_summary
