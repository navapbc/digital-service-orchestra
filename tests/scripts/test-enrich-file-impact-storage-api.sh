#!/usr/bin/env bash
# tests/scripts/test-enrich-file-impact-storage-api.sh
# RED tests for enrich-file-impact.sh storage-API refactor.
#
# These tests assert behavior AFTER enrich-file-impact.sh is refactored to use
# `ticket set-file-impact` / `ticket get-file-impact` instead of markdown parsing
# and `ticket comment`. All tests FAIL in the current (pre-refactor) state.
#
# Tests:
#   a. When `ticket get-file-impact` returns [], the script runs LLM enrichment
#      (does not short-circuit due to an existing impact stored via the new API)
#   b. When `ticket get-file-impact` returns a non-empty array, the script exits 0
#      WITHOUT calling the LLM (new API idempotency check)
#   c. After enrichment, `ticket set-file-impact` is called (not just `ticket comment`)
#
# Usage: bash tests/scripts/test-enrich-file-impact-storage-api.sh
# Returns: exit 0 if all pass (once GREEN), exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1
SCRIPT="$REPO_ROOT/plugins/dso/scripts/enrich-file-impact.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

echo "=== test-enrich-file-impact-storage-api.sh ==="

# ── Helper: create a mock ticket CLI that records all invocations ─────────────
# The mock:
#   - `ticket show <id>`            → returns a minimal JSON ticket (no file impact in description)
#   - `ticket get-file-impact <id>` → returns the value of $get_impact_output
#   - `ticket set-file-impact <id>` → records the call in $call_log, exits 0
#   - `ticket comment <id> <body>`  → records the call in $call_log, exits 0
#
# Usage: _make_recording_ticket_cli <dir> <ticket_id> <get_impact_output> <call_log>
_make_recording_ticket_cli() {
    local dir="$1"
    local ticket_id="$2"
    local get_impact_output="$3"
    local call_log="$4"

    mkdir -p "$dir"

    # Write get-file-impact response to a file so we avoid quoting pitfalls
    local impact_file="$dir/get-file-impact-response.txt"
    printf '%s\n' "$get_impact_output" > "$impact_file"

    # Write minimal ticket JSON (no file impact in description or comments)
    local ticket_json_file="$dir/ticket-show.json"
    python3 -c "
import json, sys
t = {
    'ticket_id': sys.argv[1],
    'ticket_type': 'task',
    'status': 'open',
    'title': 'Test ticket for storage API',
    'description': '## Description\nDo the thing.',
    'comments': [],
    'deps': []
}
print(json.dumps(t))
" "$ticket_id" > "$ticket_json_file"

    cat > "$dir/ticket" << TICKET_SCRIPT
#!/usr/bin/env bash
SUBCMD="\${1:-}"
shift || true
CALL_LOG="$call_log"
IMPACT_FILE="$impact_file"
TICKET_JSON="$ticket_json_file"

echo "\$SUBCMD \$*" >> "\$CALL_LOG"

case "\$SUBCMD" in
    show)
        cat "\$TICKET_JSON"
        exit 0
        ;;
    get-file-impact)
        cat "\$IMPACT_FILE"
        exit 0
        ;;
    set-file-impact)
        # Record the set call and exit 0
        exit 0
        ;;
    comment)
        # Record the comment call and exit 0
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
TICKET_SCRIPT
    chmod +x "$dir/ticket"
}

# ── Test a: empty get-file-impact → proceeds to LLM enrichment ───────────────
# When `ticket get-file-impact` returns `[]` (empty JSON array), the script
# should NOT short-circuit. It should reach the LLM call path (or --dry-run exit).
# RED: current enrich-file-impact.sh does not call `ticket get-file-impact` at all —
# it parses the description for markdown ## File Impact. The description has none,
# so it proceeds to enrichment — this test PASSES currently. BUT the assertion below
# checks that the mock's `get-file-impact` subcommand was actually invoked, which
# it will NOT be until the refactor. That assertion is the RED gate.
echo ""
echo "Test a: empty get-file-impact → script proceeds (not short-circuited by API)"

_ta_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_ta_dir")
_ta_call_log=$(mktemp)
_CLEANUP_DIRS+=("$_ta_call_log")

# get-file-impact returns an empty JSON array
_make_recording_ticket_cli "$_ta_dir" "ta-task-1" "[]" "$_ta_call_log"

_ta_exit=0
_ta_output=$(TICKET_CMD="$_ta_dir/ticket" ANTHROPIC_API_KEY="fake-key-for-test" \
    bash "$SCRIPT" --dry-run "ta-task-1" 2>&1) || _ta_exit=$?

# Script must exit 0 (dry-run exits before actual API call)
assert_eq "empty-get-impact: exits 0 in dry-run" "0" "$_ta_exit"

# KEY ASSERTION (RED): `ticket get-file-impact ta-task-1` must have been called
_ta_calls=$(cat "$_ta_call_log")
_ta_gfi_called=0
grep -q "get-file-impact ta-task-1" "$_ta_call_log" && _ta_gfi_called=1 || true
assert_eq "empty-get-impact: ticket get-file-impact was called (new API idempotency)" "1" "$_ta_gfi_called"

# ── Test b: non-empty get-file-impact → script exits 0 without calling LLM ───
# When `ticket get-file-impact` returns a non-empty JSON array, the script
# should exit 0 immediately (already enriched via new API), WITHOUT reaching
# the LLM enrichment path.
# RED: current script doesn't call `ticket get-file-impact` so it falls through
# to the markdown check, which finds no section and proceeds to LLM. With
# ANTHROPIC_API_KEY=fake, it will call the real API or fail — not exit 0 cleanly
# with an "already enriched" message.
echo ""
echo "Test b: non-empty get-file-impact → early exit 0 (idempotency via new API)"

_tb_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_tb_dir")
_tb_call_log=$(mktemp)
_CLEANUP_DIRS+=("$_tb_call_log")

# get-file-impact returns a non-empty JSON array (already enriched)
_tb_impact_json='[{"file":"src/app.py","reason":"core logic"},{"file":"tests/test_app.py","reason":"unit tests"}]'
_make_recording_ticket_cli "$_tb_dir" "tb-task-1" "$_tb_impact_json" "$_tb_call_log"

_tb_exit=0
_tb_output=$(TICKET_CMD="$_tb_dir/ticket" ANTHROPIC_API_KEY="fake-key-for-test" \
    bash "$SCRIPT" "tb-task-1" 2>&1) || _tb_exit=$?

# Script must exit 0 (short-circuit: already enriched)
assert_eq "non-empty-get-impact: exits 0 without calling LLM" "0" "$_tb_exit"

# KEY ASSERTION (RED): output must indicate "already" enriched
_tb_output_lower=$(echo "$_tb_output" | tr '[:upper:]' '[:lower:]')
_tb_already_found=0
echo "$_tb_output_lower" | grep -qE "(already|already enriched|file impact already)" && _tb_already_found=1 || true
assert_eq "non-empty-get-impact: output indicates already enriched" "1" "$_tb_already_found"

# KEY ASSERTION (RED): `ticket get-file-impact` must have been called
_tb_gfi_called=0
grep -q "get-file-impact tb-task-1" "$_tb_call_log" && _tb_gfi_called=1 || true
assert_eq "non-empty-get-impact: ticket get-file-impact was called" "1" "$_tb_gfi_called"

# KEY ASSERTION (RED): `ticket set-file-impact` must NOT have been called
_tb_sfi_called=0
grep -q "set-file-impact" "$_tb_call_log" && _tb_sfi_called=1 || true
assert_eq "non-empty-get-impact: ticket set-file-impact was NOT called (already done)" "0" "$_tb_sfi_called"

# ── Test c: after enrichment, set-file-impact is called (not just comment) ───
# After the LLM returns a file impact response, the script must store it via
# `ticket set-file-impact <id> <json>` (not just `ticket comment`).
# RED: current script calls `ticket comment`, never `ticket set-file-impact`.
# We use --dry-run here to avoid a real LLM call, then verify the CLI mock
# records the call pattern. Since --dry-run exits before storing, we need a
# slightly different approach: inject a mock that simulates an LLM response
# via a wrapper script that overrides curl behavior.
echo ""
echo "Test c: after enrichment, ticket set-file-impact is called (storage via new API)"

_tc_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_tc_dir")
_tc_call_log=$(mktemp)
_CLEANUP_DIRS+=("$_tc_call_log")

# get-file-impact returns [] (not yet enriched)
_make_recording_ticket_cli "$_tc_dir" "tc-task-1" "[]" "$_tc_call_log"

# Create a mock curl that returns a canned API response
_tc_bin_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_tc_bin_dir")
# shellcheck disable=SC2016  # single quotes intentional: literal \n is JSON escape, not shell expansion
_tc_api_response='{"content":[{"type":"text","text":"## File Impact\n- `src/core.py` - core logic\n- `tests/test_core.py` - unit tests"}]}'
cat > "$_tc_bin_dir/curl" << CURL_SCRIPT
#!/usr/bin/env bash
# Mock curl — returns a canned Anthropic API response
printf '%s\n' '$_tc_api_response'
CURL_SCRIPT
chmod +x "$_tc_bin_dir/curl"

_tc_exit=0
_tc_output=$(PATH="$_tc_bin_dir:$PATH" TICKET_CMD="$_tc_dir/ticket" \
    ANTHROPIC_API_KEY="fake-key-for-test" \
    bash "$SCRIPT" "tc-task-1" 2>&1) || _tc_exit=$?

# Script must complete without error
assert_eq "set-file-impact-after-enrich: exits 0" "0" "$_tc_exit"

# KEY ASSERTION (RED): `ticket set-file-impact tc-task-1` must have been called
_tc_sfi_called=0
grep -q "set-file-impact tc-task-1" "$_tc_call_log" && _tc_sfi_called=1 || true
assert_eq "set-file-impact-after-enrich: ticket set-file-impact was called after LLM" "1" "$_tc_sfi_called"

# KEY ASSERTION (RED): The comment subcommand must NOT be the sole storage path
# (after refactor, set-file-impact is primary; comment may also be recorded for
# backward compat, but set-file-impact MUST be present)
_tc_comment_only=0
if grep -q "comment tc-task-1" "$_tc_call_log" && ! grep -q "set-file-impact tc-task-1" "$_tc_call_log"; then
    _tc_comment_only=1
fi
assert_eq "set-file-impact-after-enrich: NOT comment-only storage (set-file-impact required)" "0" "$_tc_comment_only"

echo ""
print_summary
