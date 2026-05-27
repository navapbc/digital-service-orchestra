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
    TMPHOME=$(mktemp -d /tmp/test-gate-unavailable.XXXXXX)
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
    assert_contains "audit has gate_name" '"gate_name":"test_gate"' "$_line"
    assert_contains "audit has reason" '"reason":"timeout sig=15"' "$_line"
    assert_contains "audit has session_id" '"session_id":"sess-001"' "$_line"
    assert_contains "audit has ticket_id" '"ticket_id":"tkt-001"' "$_line"
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

# ── Run all ──────────────────────────────────────────────────────────────────
test_unavailable_writes_jsonl_audit
test_unavailable_resolves_unknown_when_session_missing
test_unavailable_emits_stderr_signal
test_unavailable_returns_zero
test_unavailable_json_escaping_for_quotes
test_bypass_inactive_when_no_env_set
test_bypass_inactive_when_flag_alone
test_bypass_active_when_both_env_set
test_bypass_active_writes_audit_record
test_bypass_uppercase_normalization

print_summary
