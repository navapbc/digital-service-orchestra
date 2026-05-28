#!/usr/bin/env bash
# tests/scripts/test-gate-unavailable.sh
# F-02: tests for the _dso_gate_unavailable and _dso_gate_bypass_active
# helpers (plugins/dso/hooks/lib/gate-unavailable.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"

SUT="$REPO_ROOT/plugins/dso/hooks/lib/gate-unavailable.sh"

# ── Scaffolding ──────────────────────────────────────────────────────────────
TMPHOME=""
_setup() {
    TMPHOME=$(mktemp -d "${TMPDIR:-/tmp}/test-gate-unavailable.XXXXXX")
    export HOME="$TMPHOME"
    mkdir -p "$HOME/.claude/logs"
    unset _DSO_GATE_UNAVAILABLE_LIB
}
_teardown() {
    [[ -n "$TMPHOME" ]] && rm -rf "$TMPHOME"
    TMPHOME=""
}
trap _teardown EXIT

_source_sut() {
    # Re-source for each test so the include-guard doesn't suppress reloading
    unset _DSO_GATE_UNAVAILABLE_LIB
    # shellcheck source=/dev/null
    source "$SUT"
}

# ── Tests: _dso_gate_unavailable ─────────────────────────────────────────────

test_unavailable_writes_jsonl_audit() {
    _setup
    _source_sut
    DSO_SESSION_ID="sess-001" DSO_TICKET_ID="tkt-001" \
        _dso_gate_unavailable test_gate "timeout sig=15" 2>/dev/null
    local _log="$HOME/.claude/logs/dso-gate-unavailable.jsonl"
    assert_eq "audit log file exists" "1" "$([[ -f "$_log" ]] && echo 1 || echo 0)"
    local _line
    _line=$(head -1 "$_log")
    # Assert ALL six documented audit fields. Missing any field is a
    # contract violation discoverable only via this test (the helper's
    # printf would silently emit a record without it).
    assert_contains "audit has timestamp field" '"timestamp":"' "$_line"
    assert_contains "audit has gate_name" '"gate_name":"test_gate"' "$_line"
    assert_contains "audit has reason" '"reason":"timeout sig=15"' "$_line"
    assert_contains "audit has session_id" '"session_id":"sess-001"' "$_line"
    assert_contains "audit has ticket_id" '"ticket_id":"tkt-001"' "$_line"
    assert_contains "audit has actor field" '"actor":"' "$_line"
    # Verify timestamp matches the documented format (UTC ISO-8601 with "Z").
    if printf '%s' "$_line" | grep -qE '"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"'; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: timestamp does not match ISO-8601 UTC format" >&2
    fi
    _teardown
}

test_unavailable_resolves_unknown_when_session_missing() {
    _setup
    _source_sut
    unset DSO_SESSION_ID SPRINT_SESSION_ID CLAUDE_SESSION_ID
    unset DSO_TICKET_ID TICKET_ID PRIMARY_TICKET_ID
    _dso_gate_unavailable some_gate "reason text" 2>/dev/null
    local _line
    _line=$(head -1 "$HOME/.claude/logs/dso-gate-unavailable.jsonl")
    assert_contains "session_id falls back to unknown" '"session_id":"unknown"' "$_line"
    assert_contains "ticket_id falls back to unknown" '"ticket_id":"unknown"' "$_line"
    _teardown
}

test_unavailable_emits_stderr_signal() {
    _setup
    _source_sut
    local _stderr
    _stderr=$(_dso_gate_unavailable review_gate "hash_compute_failed" 2>&1 1>/dev/null)
    assert_contains "stderr signal contains gate name" "gate=review_gate" "$_stderr"
    assert_contains "stderr signal contains reason" "reason=hash_compute_failed" "$_stderr"
    _teardown
}

test_unavailable_returns_zero() {
    _setup
    _source_sut
    local _rc=0
    _dso_gate_unavailable test_gate "any reason" 2>/dev/null || _rc=$?
    assert_eq "_dso_gate_unavailable returns 0" "0" "$_rc"
    _teardown
}

test_unavailable_json_escaping_for_quotes() {
    _setup
    _source_sut
    _dso_gate_unavailable test_gate 'reason with "quoted" parts' 2>/dev/null
    local _line
    _line=$(head -1 "$HOME/.claude/logs/dso-gate-unavailable.jsonl")
    # Verify the JSON is parseable (i.e., escaping worked) — pipe through python
    local _parsed_reason
    _parsed_reason=$(printf '%s\n' "$_line" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])" 2>/dev/null || echo "PARSE_FAILED")
    assert_eq "JSON quotes escaped correctly" 'reason with "quoted" parts' "$_parsed_reason"
    _teardown
}

test_unavailable_json_escaping_for_backslash() {
    # Backslash escape MUST run before double-quote escape — otherwise the
    # double-quote escape's own backslash gets escaped twice. Verify by
    # round-tripping through python json.loads.
    _setup
    _source_sut
    _dso_gate_unavailable test_gate 'path with C:\Windows\backslashes' 2>/dev/null
    local _line
    _line=$(head -1 "$HOME/.claude/logs/dso-gate-unavailable.jsonl")
    local _parsed_reason
    _parsed_reason=$(printf '%s\n' "$_line" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])" 2>/dev/null || echo "PARSE_FAILED")
    assert_eq "JSON backslash escaped correctly" 'path with C:\Windows\backslashes' "$_parsed_reason"
    _teardown
}

test_unavailable_json_escaping_for_newline_and_tab() {
    # Control characters (newline, tab, carriage return) inside a JSON string
    # value produce invalid JSON unless escaped. A regression that drops the
    # newline/tab escape breaks downstream JSONL readers silently — the audit
    # log is appended to and parsed line-by-line, so one malformed line
    # corrupts all subsequent reads of the same file.
    _setup
    _source_sut
    # Build a reason containing literal newline + tab via $'...' quoting.
    local _multi_reason
    _multi_reason=$'line1\nline2\twith-tab\rcr'
    _dso_gate_unavailable test_gate "$_multi_reason" 2>/dev/null
    local _line
    _line=$(head -1 "$HOME/.claude/logs/dso-gate-unavailable.jsonl")
    # The whole JSONL line must be a single physical line (no embedded newlines).
    local _line_count
    _line_count=$(wc -l < "$HOME/.claude/logs/dso-gate-unavailable.jsonl")
    assert_eq "JSONL record is exactly one physical line" "1" "$_line_count"
    # And it must parse cleanly.
    local _parsed_reason
    _parsed_reason=$(printf '%s\n' "$_line" | python3 -c "import json,sys; print(repr(json.load(sys.stdin)['reason']))" 2>/dev/null || echo "PARSE_FAILED")
    # Python repr of the parsed reason should contain the escaped forms after
    # round-trip (i.e., python sees the original control chars).
    assert_contains "reason round-trips literal newline" 'line1\nline2' "$_parsed_reason"
    assert_contains "reason round-trips literal tab" '\twith-tab' "$_parsed_reason"
    _teardown
}

# ── Tests: _dso_gate_bypass_active ───────────────────────────────────────────

test_bypass_inactive_when_no_env_set() {
    _setup
    _source_sut
    unset DSO_GATE_BYPASS_TEST_GATE DSO_GATE_BYPASS_TEST_GATE_REASON
    local _rc=0
    _dso_gate_bypass_active test_gate 2>/dev/null || _rc=$?
    assert_eq "bypass inactive when env unset" "1" "$_rc"
    _teardown
}

test_bypass_inactive_when_flag_alone() {
    _setup
    _source_sut
    DSO_GATE_BYPASS_TEST_GATE=1 \
    DSO_GATE_BYPASS_TEST_GATE_REASON="" \
        bash -c '
            source "$1"
            DSO_GATE_BYPASS_TEST_GATE=1 \
            DSO_GATE_BYPASS_TEST_GATE_REASON="" \
                _dso_gate_bypass_active test_gate 2>/dev/null
        ' _ "$SUT"
    local _rc=$?
    assert_eq "bypass inactive when REASON empty" "1" "$_rc"
    _teardown
}

test_bypass_active_when_both_env_set() {
    _setup
    _source_sut
    local _rc=0
    DSO_GATE_BYPASS_TEST_GATE=1 \
    DSO_GATE_BYPASS_TEST_GATE_REASON="testing fail-closed" \
        _dso_gate_bypass_active test_gate 2>/dev/null || _rc=$?
    assert_eq "bypass active when both env vars set" "0" "$_rc"
    _teardown
}

test_bypass_active_writes_audit_record() {
    _setup
    _source_sut
    DSO_GATE_BYPASS_REVIEW_GATE=1 \
    DSO_GATE_BYPASS_REVIEW_GATE_REASON="experimental run" \
    DSO_SESSION_ID="sess-bypass-001" DSO_TICKET_ID="tkt-bypass-001" \
        _dso_gate_bypass_active review_gate 2>/dev/null
    local _log="$HOME/.claude/logs/dso-gate-unavailable.jsonl"
    assert_eq "bypass audit log created" "1" "$([[ -f "$_log" ]] && echo 1 || echo 0)"
    local _line
    _line=$(head -1 "$_log")
    assert_contains "bypass event marker present" '"event":"bypass_active"' "$_line"
    assert_contains "bypass audit has gate_name" '"gate_name":"review_gate"' "$_line"
    assert_contains "bypass audit has reason" '"reason":"experimental run"' "$_line"
    _teardown
}

test_bypass_uppercase_normalization() {
    # The lookup uppercases the gate name; verify lower-case gate name finds
    # DSO_GATE_BYPASS_TEST_GATE (uppercase form).
    _setup
    _source_sut
    local _rc=0
    DSO_GATE_BYPASS_MY_GATE=1 \
    DSO_GATE_BYPASS_MY_GATE_REASON="ok" \
        _dso_gate_bypass_active my_gate 2>/dev/null || _rc=$?
    assert_eq "lower-case gate name resolves to uppercase env var" "0" "$_rc"
    _teardown
}

test_bypass_rejects_hyphen_in_gate_name() {
    # Bash env var names cannot contain hyphens. A gate name like 'review-gate'
    # would produce DSO_GATE_BYPASS_REVIEW-GATE which is an invalid bash
    # identifier; the indirect ${!var} lookup would emit a hard error suppressed
    # by 2>/dev/null at the call site, silently breaking the bypass. Validate
    # the gate name at the helper boundary instead.
    _setup
    _source_sut
    local _rc=0
    DSO_GATE_BYPASS_REVIEW_GATE=1 \
    DSO_GATE_BYPASS_REVIEW_GATE_REASON="ok" \
        _dso_gate_bypass_active 'review-gate' 2>/dev/null || _rc=$?
    assert_eq "hyphenated gate name rejected" "1" "$_rc"
    _teardown
}

test_bypass_rejects_dot_in_gate_name() {
    _setup
    _source_sut
    local _rc=0
    _dso_gate_bypass_active 'gate.name' 2>/dev/null || _rc=$?
    assert_eq "dotted gate name rejected" "1" "$_rc"
    _teardown
}

test_bypass_rejects_uppercase_in_gate_name() {
    # The pattern [a-z_][a-z0-9_]* enforces lower-case gate names so the
    # uppercase-for-env-var-lookup transform is well-defined.
    _setup
    _source_sut
    local _rc=0
    _dso_gate_bypass_active 'TestGate' 2>/dev/null || _rc=$?
    assert_eq "uppercase gate name rejected" "1" "$_rc"
    _teardown
}

test_bypass_rejection_emits_actionable_error() {
    _setup
    _source_sut
    local _stderr
    _stderr=$(_dso_gate_bypass_active 'bad-name' 2>&1)
    assert_contains "rejection mentions identifier pattern" "valid bash identifier" "$_stderr"
    _teardown
}

# ── Run all ──────────────────────────────────────────────────────────────────
test_unavailable_writes_jsonl_audit
test_unavailable_resolves_unknown_when_session_missing
test_unavailable_emits_stderr_signal
test_unavailable_returns_zero
test_unavailable_json_escaping_for_quotes
test_unavailable_json_escaping_for_backslash
test_unavailable_json_escaping_for_newline_and_tab
test_bypass_inactive_when_no_env_set
test_bypass_inactive_when_flag_alone
test_bypass_active_when_both_env_set
test_bypass_active_writes_audit_record
test_bypass_uppercase_normalization
test_bypass_rejects_hyphen_in_gate_name
test_bypass_rejects_dot_in_gate_name
test_bypass_rejects_uppercase_in_gate_name
test_bypass_rejection_emits_actionable_error

print_summary
