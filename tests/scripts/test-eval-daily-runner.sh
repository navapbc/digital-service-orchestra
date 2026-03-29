#!/usr/bin/env bash
# tests/scripts/test-eval-daily-runner.sh
# RED-phase behavioral tests for plugins/dso/scripts/eval-daily-runner.sh
#
# Usage: bash tests/scripts/test-eval-daily-runner.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: All tests are expected to FAIL until eval-daily-runner.sh is implemented
#       (RED phase of TDD). The script under test does not yet exist.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/eval-daily-runner.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-eval-daily-runner.sh ==="

# ── Temp dir setup with EXIT trap cleanup ─────────────────────────────────────
_TEST_TMPDIRS=()
trap 'rm -rf "${_TEST_TMPDIRS[@]}"' EXIT

# ── Helper: create an isolated mock bin dir ────────────────────────────────────
# Writes mock run-skill-evals.sh and a ticket CLI stub into a temp bin dir.
# The ticket CLI stub records every subcommand + arguments to a calls log file.
#
# Usage: _make_mock_bin <dir> <eval_exit_code> [eval_stdout]
# Outputs (side effects on dir):
#   <dir>/run-skill-evals.sh  — exits <eval_exit_code>, prints [eval_stdout]
#   <dir>/dso                 — records ticket subcommand calls to <dir>/ticket-calls.log
#   <dir>/ticket-calls.log    — created empty on init
#
# The ticket "list" subcommand output is controlled via the DSO_MOCK_TICKET_LIST
# environment variable (set it before invoking eval-daily-runner.sh).
_make_mock_bin() {
    local dir="$1" eval_exit_code="$2" eval_stdout="${3:-}"
    mkdir -p "$dir"

    # Mock run-skill-evals.sh
    cat > "$dir/run-skill-evals.sh" <<STUB
#!/usr/bin/env bash
${eval_stdout:+printf '%s\n' "$eval_stdout"}
exit $eval_exit_code
STUB
    chmod +x "$dir/run-skill-evals.sh"

    # Create empty calls log
    touch "$dir/ticket-calls.log"

    # Mock dso ticket CLI — records all args to ticket-calls.log
    # "ticket list" output is controlled by DSO_MOCK_TICKET_LIST env var
    cat > "$dir/dso" <<'STUB'
#!/usr/bin/env bash
# Record all arguments for later assertion
printf '%s\n' "$*" >> "${MOCK_BIN_DIR}/ticket-calls.log"
# Handle "ticket list" specially — return controlled output
if [[ "${1:-}" == "ticket" && "${2:-}" == "list" ]]; then
    printf '%s\n' "${DSO_MOCK_TICKET_LIST:-}"
    exit 0
fi
# All other subcommands succeed silently
exit 0
STUB
    chmod +x "$dir/dso"
}

# ── test_no_ticket_on_success ──────────────────────────────────────────────────
# When run-skill-evals.sh exits 0, eval-daily-runner.sh must NOT invoke the
# ticket CLI for create or comment — no ticket action is warranted.
# Observable: ticket-calls.log contains no "ticket create" or "ticket comment"
#             entries; script exits 0.
# RED: script does not exist — bash exits 127, assertions about call log fail.

echo ""
echo "test_no_ticket_on_success"

TMPDIR_SUCCESS="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_SUCCESS")
_make_mock_bin "$TMPDIR_SUCCESS" 0 "All evals passed"

success_exit=0
success_output=""
success_output=$(
    MOCK_BIN_DIR="$TMPDIR_SUCCESS" \
    DSO_MOCK_TICKET_LIST="" \
    PATH="$TMPDIR_SUCCESS:/usr/bin:/bin" \
    bash "$SCRIPT" 2>&1
) || success_exit=$?

assert_eq "test_no_ticket_on_success: exits 0" "0" "$success_exit"

success_calls="$(cat "$TMPDIR_SUCCESS/ticket-calls.log" 2>/dev/null || true)"
# Neither "ticket create" nor "ticket comment" should appear in the call log
create_found=""
comment_found=""
[[ "$success_calls" == *"ticket create"* ]] && create_found="yes"
[[ "$success_calls" == *"ticket comment"* ]] && comment_found="yes"
assert_eq "test_no_ticket_on_success: no ticket create call" "" "$create_found"
assert_eq "test_no_ticket_on_success: no ticket comment call" "" "$comment_found"

# ── test_creates_p0_bug_on_failure ────────────────────────────────────────────
# When run-skill-evals.sh exits 1 and no existing P0 EVAL REGRESSION ticket
# exists, eval-daily-runner.sh must call "dso ticket create bug" with a title
# that starts with "EVAL REGRESSION:" and priority 0.
# Observable: ticket-calls.log contains a "ticket create" line with the required
#             title prefix; script exits non-zero.
# RED: script does not exist — bash exits 127 without writing to the call log.

echo ""
echo "test_creates_p0_bug_on_failure"

TMPDIR_FAILURE="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_FAILURE")
# Eval output with one failing skill
FAIL_OUTPUT="FAILED: fix-bug
1 skill(s) failing"
_make_mock_bin "$TMPDIR_FAILURE" 1 "$FAIL_OUTPUT"

failure_exit=0
failure_output=""
failure_output=$(
    MOCK_BIN_DIR="$TMPDIR_FAILURE" \
    DSO_MOCK_TICKET_LIST="" \
    PATH="$TMPDIR_FAILURE:/usr/bin:/bin" \
    bash "$SCRIPT" 2>&1
) || failure_exit=$?

assert_ne "test_creates_p0_bug_on_failure: exits non-zero" "0" "$failure_exit"

failure_calls="$(cat "$TMPDIR_FAILURE/ticket-calls.log" 2>/dev/null || true)"
assert_contains "test_creates_p0_bug_on_failure: ticket create called" \
    "ticket create" "$failure_calls"
assert_contains "test_creates_p0_bug_on_failure: title starts with EVAL REGRESSION:" \
    "EVAL REGRESSION:" "$failure_calls"

# Check that priority 0 was passed — the CLI call should contain "-p 0" or "--priority 0" or "-p0"
priority_found=""
if [[ "$failure_calls" == *"-p 0"* ]] || [[ "$failure_calls" == *"--priority 0"* ]] || [[ "$failure_calls" == *"-p0"* ]]; then
    priority_found="yes"
fi
assert_eq "test_creates_p0_bug_on_failure: priority 0 specified" "yes" "$priority_found"

# ── test_dedup_appends_comment_to_existing_p0 ─────────────────────────────────
# When run-skill-evals.sh exits 1 AND an open P0 ticket with "EVAL REGRESSION:"
# prefix already exists, eval-daily-runner.sh must call "dso ticket comment"
# (not "dso ticket create") so that duplicates are avoided.
# Observable: ticket-calls.log contains "ticket comment" but NOT "ticket create".
# RED: script does not exist — call log stays empty.

echo ""
echo "test_dedup_appends_comment_to_existing_p0"

TMPDIR_DEDUP="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_DEDUP")
_make_mock_bin "$TMPDIR_DEDUP" 1 "FAILED: sprint
1 skill(s) failing"

# Simulate an existing open P0 EVAL REGRESSION ticket in the list output
EXISTING_LIST='[{"ticket_id":"abcd-1234","title":"EVAL REGRESSION: 2026-03-27 — 1 skills failing","status":"open","priority":0}]'

dedup_exit=0
dedup_output=""
dedup_output=$(
    MOCK_BIN_DIR="$TMPDIR_DEDUP" \
    DSO_MOCK_TICKET_LIST="$EXISTING_LIST" \
    PATH="$TMPDIR_DEDUP:/usr/bin:/bin" \
    bash "$SCRIPT" 2>&1
) || dedup_exit=$?

dedup_calls="$(cat "$TMPDIR_DEDUP/ticket-calls.log" 2>/dev/null || true)"

# Must call comment (not create) when existing ticket found
assert_contains "test_dedup_appends_comment_to_existing_p0: ticket comment called" \
    "ticket comment" "$dedup_calls"

no_create_when_dedup=""
[[ "$dedup_calls" == *"ticket create"* ]] && no_create_when_dedup="yes"
assert_eq "test_dedup_appends_comment_to_existing_p0: no ticket create when existing P0" \
    "" "$no_create_when_dedup"

# ── test_title_format_contains_date_and_count ─────────────────────────────────
# The created ticket title must contain a YYYY-MM-DD date and the failure count
# parsed from eval output (e.g. "EVAL REGRESSION: 2026-03-28 — 2 skills failing").
# Observable: ticket-calls.log contains a line with a date matching [0-9]{4}-[0-9]{2}-[0-9]{2}
#             and a digit before "skill".
# RED: script does not exist — call log stays empty.

echo ""
echo "test_title_format_contains_date_and_count"

TMPDIR_TITLE="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_TITLE")
_make_mock_bin "$TMPDIR_TITLE" 1 "FAILED: fix-bug
FAILED: sprint
2 skill(s) failing"

title_exit=0
title_output=""
title_output=$(
    MOCK_BIN_DIR="$TMPDIR_TITLE" \
    DSO_MOCK_TICKET_LIST="" \
    PATH="$TMPDIR_TITLE:/usr/bin:/bin" \
    bash "$SCRIPT" 2>&1
) || title_exit=$?

title_calls="$(cat "$TMPDIR_TITLE/ticket-calls.log" 2>/dev/null || true)"

# Verify a YYYY-MM-DD date pattern appears in the ticket create call
date_found=""
if [[ "$title_calls" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    date_found="yes"
fi
assert_eq "test_title_format_contains_date_and_count: title contains YYYY-MM-DD date" \
    "yes" "$date_found"

# Verify a digit followed by "skill" appears (the failure count)
count_found=""
if [[ "$title_calls" =~ [0-9]+\ skill ]]; then
    count_found="yes"
fi
assert_eq "test_title_format_contains_date_and_count: title contains failure count" \
    "yes" "$count_found"

# ── test_exits_nonzero_on_eval_failure ────────────────────────────────────────
# The script must propagate a non-zero exit code whenever run-skill-evals.sh
# exits non-zero, so CI pipelines that invoke eval-daily-runner.sh see the
# failure and mark the run red.
# Observable: eval-daily-runner.sh exit code is non-zero when evals fail.
# RED: script does not exist — bash exits 127 (still non-zero, but the test
#      verifies the exact mechanism once GREEN; for RED the assertion about
#      the specific behavior still fails because the script path is absent).

echo ""
echo "test_exits_nonzero_on_eval_failure"

TMPDIR_PROPAGATE="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_PROPAGATE")
_make_mock_bin "$TMPDIR_PROPAGATE" 2 "eval runner internal error"

# Confirm the script itself is absent (RED condition)
if [[ ! -f "$SCRIPT" ]]; then
    assert_eq "test_exits_nonzero_on_eval_failure: script exists at expected path" \
        "exists" "missing"
fi

propagate_exit=0
propagate_output=""
propagate_output=$(
    MOCK_BIN_DIR="$TMPDIR_PROPAGATE" \
    DSO_MOCK_TICKET_LIST="" \
    PATH="$TMPDIR_PROPAGATE:/usr/bin:/bin" \
    bash "$SCRIPT" 2>&1
) || propagate_exit=$?

# Exit code must be non-zero; the exact value is implementation-defined but must
# not be 0.
assert_ne "test_exits_nonzero_on_eval_failure: propagates non-zero exit" \
    "0" "$propagate_exit"

# When the script is present, also assert it is not exit 127 (missing binary)
# by checking the output does not contain "No such file" from bash itself.
no_such_file=""
[[ "$propagate_output" == *"No such file"* ]] && no_such_file="yes"
assert_eq "test_exits_nonzero_on_eval_failure: non-zero exit is from script logic, not missing binary" \
    "" "$no_such_file"

print_summary
