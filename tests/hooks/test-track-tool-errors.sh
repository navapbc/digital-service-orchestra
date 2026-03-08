#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-track-tool-errors.sh
# Tests for .claude/hooks/track-tool-errors.sh
#
# track-tool-errors.sh is a PostToolUseFailure hook that categorizes and counts
# tool errors, and creates a bug ticket when any category reaches 50 occurrences.
# It always exits 0 (non-blocking).

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/track-tool-errors.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

COUNTER_FILE="$HOME/.claude/tool-error-counter.json"

run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" > /dev/null 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

run_hook_output() {
    local input="$1"
    echo "$input" | bash "$HOOK" 2>/dev/null
}

# test_track_tool_errors_exits_zero_on_interrupt
# User interrupts are skipped (is_interrupt=true) → exit 0
INPUT='{"tool_name":"Bash","error":"interrupted","is_interrupt":true}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_track_tool_errors_exits_zero_on_interrupt" "0" "$EXIT_CODE"

# test_track_tool_errors_exits_zero_on_empty_error
# No error message → skip silently, exit 0
INPUT='{"tool_name":"Bash","error":""}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_track_tool_errors_exits_zero_on_empty_error" "0" "$EXIT_CODE"

# test_track_tool_errors_exits_zero_on_normal_error
# Normal tool error → categorize, increment counter, exit 0
# Back up and remove the counter file so we start clean
_ORIG_COUNTER=""
if [[ -f "$COUNTER_FILE" ]]; then
    _ORIG_COUNTER=$(cat "$COUNTER_FILE")
    rm -f "$COUNTER_FILE"
fi

INPUT='{"tool_name":"Read","error":"file not found: /tmp/test.txt","is_interrupt":false}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_track_tool_errors_exits_zero_on_normal_error" "0" "$EXIT_CODE"

# Restore counter file
if [[ -n "$_ORIG_COUNTER" ]]; then
    echo "$_ORIG_COUNTER" > "$COUNTER_FILE"
else
    rm -f "$COUNTER_FILE"
fi

# test_track_tool_errors_exits_zero_on_malformed_json
# Malformed JSON → exit 0 (fail-open)
EXIT_CODE=$(run_hook "not json {{")
assert_eq "test_track_tool_errors_exits_zero_on_malformed_json" "0" "$EXIT_CODE"

# ============================================================
# Group: bd → tk migration (RED phase)
# ============================================================
# These tests verify that track-tool-errors.sh has been migrated
# away from bd. They MUST FAIL against the current bd-based implementation.

# test_track_tool_errors_no_bd_calls_remain
# grep the hook source for 'bd ' — must return zero occurrences once migrated.
# MUST FAIL in red phase: hook calls 'bd create' when threshold is reached.
_TTE_BD_COUNT=$(grep -c 'bd ' "$HOOK" 2>/dev/null; true)
assert_eq "test_track_tool_errors_no_bd_calls_remain" "0" "$_TTE_BD_COUNT"

# test_track_tool_errors_creates_tk_bug
# Stub tk in PATH. Feed hook an error that pushes counter to 50.
# Assert tk create is called (FAILS now because hook calls bd create).
_TTE_FAKE_BIN=$(mktemp -d)
_TTE_TK_LOG="$_TTE_FAKE_BIN/tk.log"

cat > "$_TTE_FAKE_BIN/tk" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$TK_LOG"
echo "Created issue: tk-004"
MOCK_EOF
chmod +x "$_TTE_FAKE_BIN/tk"

# Suppress bd so it doesn't call real bd
cat > "$_TTE_FAKE_BIN/bd" << 'MOCK_EOF'
#!/usr/bin/env bash
exit 0
MOCK_EOF
chmod +x "$_TTE_FAKE_BIN/bd"

# Back up counter file and prime it so the next call pushes the category to threshold (50)
_TTE_ORIG_COUNTER=""
if [[ -f "$COUNTER_FILE" ]]; then
    _TTE_ORIG_COUNTER=$(cat "$COUNTER_FILE")
fi

# Build a counter file where 'permission_denied' is at 49 occurrences (threshold is 50)
# So the next call will push it to 50 and trigger bug creation.
# NOTE: 'file_not_found' is in NOISE_CATEGORIES and is intentionally excluded from
# auto-bug-creation. Use 'permission_denied' (not in NOISE_CATEGORIES) instead.
cat > "$COUNTER_FILE" << 'JSON_EOF'
{"index":{"permission_denied":49},"errors":[],"bugs_created":{}}
JSON_EOF

INPUT='{"tool_name":"Read","error":"permission denied: /tmp/trigger.txt","is_interrupt":false}'
# REVIEW-DEFENSE: TK_LOG and PATH are prefixed to `bash "$HOOK"` (right side of pipe),
# not to `echo` (left side). The env vars correctly reach the hook process.
echo "$INPUT" | TK_LOG="$_TTE_TK_LOG" PATH="$_TTE_FAKE_BIN:$PATH" bash "$HOOK" >/dev/null 2>/dev/null || true

# Check that tk create was called
_TTE_TK_CALLED="no"
if [[ -f "$_TTE_TK_LOG" ]] && grep -q "create" "$_TTE_TK_LOG" 2>/dev/null; then
    _TTE_TK_CALLED="yes"
fi
assert_eq "test_track_tool_errors_creates_tk_bug" "yes" "$_TTE_TK_CALLED"

# Restore counter file
if [[ -n "$_TTE_ORIG_COUNTER" ]]; then
    echo "$_TTE_ORIG_COUNTER" > "$COUNTER_FILE"
else
    rm -f "$COUNTER_FILE"
fi
rm -rf "$_TTE_FAKE_BIN"

print_summary
