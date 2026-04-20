#!/usr/bin/env bash
# tests/test-sprint-manual-drain.sh
# RED test suite for plugins/dso/scripts/sprint-manual-drain.sh
# All tests MUST fail until the script is implemented.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DRAIN_SCRIPT="${REPO_ROOT}/plugins/dso/scripts/sprint-manual-drain.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Tests for sprint-manual-drain.sh ==="

# Guard: if script doesn't exist every test must fail, but we still run them all.
SCRIPT_MISSING=false
if [[ ! -f "$DRAIN_SCRIPT" ]]; then
    echo "  (script not found — all tests expected to fail RED)"
    SCRIPT_MISSING=true
fi

# ---------------------------------------------------------------------------
# Helper: build a minimal JSON story list file
# Usage: _make_stories_file <dir> <json-array-string>
# ---------------------------------------------------------------------------
_make_stories_file() {
    local dir="$1"
    local json="$2"
    local f="${dir}/stories.json"
    printf '%s\n' "$json" > "$f"
    echo "$f"
}

# ---------------------------------------------------------------------------
# Helper: run the drain script with a DSO_MANUAL_INPUT mock and optional
# extra env vars.  Returns exit code in $RUN_EXIT, stdout in $RUN_OUT.
# ---------------------------------------------------------------------------
_run_drain() {
    local stories_file="$1"
    local manual_input="$2"
    shift 2
    # remaining args are extra env assignments, e.g. MANUAL_CMD_TIMEOUT=2
    local extra_env=("$@")

    local tmpdir
    tmpdir="$(mktemp -d)"
    local ticket_store="${tmpdir}/ticket-store"
    mkdir -p "$ticket_store"

    # Mock "dso" command so ticket comment calls don't hit real store
    local mock_bin="${tmpdir}/bin"
    mkdir -p "$mock_bin"
    cat > "${mock_bin}/dso" <<'MOCK'
#!/usr/bin/env bash
# Mock dso shim — records calls and succeeds silently
echo "MOCK_DSO: $*" >> "${MOCK_LOG:-/dev/null}"
exit 0
MOCK
    chmod +x "${mock_bin}/dso"

    local env_prefix=(
        "DSO_MANUAL_INPUT=${manual_input}"
        "TICKET_STORE=${ticket_store}"
        "MOCK_LOG=${tmpdir}/dso-calls.log"
        "PATH=${mock_bin}:${PATH}"
    )
    env_prefix+=("${extra_env[@]}")

    RUN_OUT=""
    RUN_EXIT=0
    RUN_TICKET_STORE="$ticket_store"
    RUN_TMPDIR="$tmpdir"

    if [[ "$SCRIPT_MISSING" == "true" ]]; then
        RUN_EXIT=127
        RUN_OUT="sprint-manual-drain.sh: script not found"
        return
    fi

    set +e
    RUN_OUT=$(env "${env_prefix[@]}" bash "$DRAIN_SCRIPT" "$stories_file" 2>&1)
    RUN_EXIT=$?
    set -e
}

# ---------------------------------------------------------------------------
# 1. test_drain_done_runs_verification_command_exit_0_proceeds
# ---------------------------------------------------------------------------
test_drain_done_runs_verification_command_exit_0_proceeds() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local f
    f="$(_make_stories_file "$tmpdir" '[{"id":"st-001","title":"Deploy DB migration","instructions":"Run migration","verification_command":"exit 0","deps":[]}]')"

    _run_drain "$f" "done"

    if [[ "$RUN_EXIT" -eq 0 ]]; then
        if echo "$RUN_OUT" | grep -qi "error\|fail"; then
            fail "test_drain_done_runs_verification_command_exit_0_proceeds: output contained error text"
        else
            pass "test_drain_done_runs_verification_command_exit_0_proceeds"
        fi
    else
        fail "test_drain_done_runs_verification_command_exit_0_proceeds: expected exit 0, got $RUN_EXIT"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 2. test_drain_done_re_prompts_on_verification_command_fail
# ---------------------------------------------------------------------------
test_drain_done_re_prompts_on_verification_command_fail() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local f
    f="$(_make_stories_file "$tmpdir" '[{"id":"st-002","title":"Check service health","instructions":"Verify pod is green","verification_command":"exit 1","deps":[]}]')"

    _run_drain "$f" "done"

    if [[ "$RUN_EXIT" -eq 2 ]]; then
        pass "test_drain_done_re_prompts_on_verification_command_fail"
    else
        fail "test_drain_done_re_prompts_on_verification_command_fail: expected exit 2, got $RUN_EXIT"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 3. test_drain_done_re_prompts_on_timeout
# ---------------------------------------------------------------------------
test_drain_done_re_prompts_on_timeout() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local f
    f="$(_make_stories_file "$tmpdir" '[{"id":"st-003","title":"Hang forever","instructions":"Wait","verification_command":"sleep 9999","deps":[]}]')"

    local start_ts
    start_ts=$(date +%s)

    _run_drain "$f" "done" "MANUAL_CMD_TIMEOUT=2"

    local elapsed=$(( $(date +%s) - start_ts ))

    if [[ "$elapsed" -le 10 ]]; then
        if echo "$RUN_OUT" | grep -qi "timeout"; then
            pass "test_drain_done_re_prompts_on_timeout"
        else
            fail "test_drain_done_re_prompts_on_timeout: output did not contain 'timeout' (got: $RUN_OUT)"
        fi
    else
        fail "test_drain_done_re_prompts_on_timeout: script ran for ${elapsed}s (expected <= 10s)"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 4. test_drain_dangerous_pattern_rejected
# ---------------------------------------------------------------------------
test_drain_dangerous_pattern_rejected() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local f
    f="$(_make_stories_file "$tmpdir" '[{"id":"st-004","title":"Dangerous cleanup","instructions":"Do not run","verification_command":"rm -rf /tmp/test123","deps":[]}]')"

    _run_drain "$f" "done"

    if [[ "$RUN_EXIT" -eq 2 ]]; then
        if echo "$RUN_OUT" | grep -qiE "dangerous pattern|rejected"; then
            pass "test_drain_dangerous_pattern_rejected"
        else
            fail "test_drain_dangerous_pattern_rejected: exit 2 but output missing 'dangerous pattern'/'rejected' (got: $RUN_OUT)"
        fi
    else
        fail "test_drain_dangerous_pattern_rejected: expected exit 2, got $RUN_EXIT"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 5. test_drain_oversize_command_rejected
# ---------------------------------------------------------------------------
test_drain_oversize_command_rejected() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    # Build a verification_command of 501 characters (safe content, just padding)
    local long_cmd
    long_cmd="$(python3 -c "print('echo ' + 'x'*497)")"

    local json
    json="$(printf '[{"id":"st-005","title":"Oversize cmd","instructions":"noop","verification_command":"%s","deps":[]}]' "$long_cmd")"
    local f
    f="$(_make_stories_file "$tmpdir" "$json")"

    _run_drain "$f" "done"

    if [[ "$RUN_EXIT" -eq 2 ]]; then
        if echo "$RUN_OUT" | grep -qiE "exceeds length limit|too long"; then
            pass "test_drain_oversize_command_rejected"
        else
            fail "test_drain_oversize_command_rejected: exit 2 but missing length-limit message (got: $RUN_OUT)"
        fi
    else
        fail "test_drain_oversize_command_rejected: expected exit 2, got $RUN_EXIT"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 6. test_drain_skip_exits_1
# ---------------------------------------------------------------------------
test_drain_skip_exits_1() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local f
    f="$(_make_stories_file "$tmpdir" '[{"id":"st-006","title":"Skip me","instructions":"Manual action","verification_command":null,"deps":[]}]')"

    _run_drain "$f" "skip"

    if [[ "$RUN_EXIT" -eq 1 ]]; then
        if echo "$RUN_OUT" | grep -qiE "skip|SKIP"; then
            pass "test_drain_skip_exits_1"
        else
            fail "test_drain_skip_exits_1: exit 1 but output missing 'skip' (got: $RUN_OUT)"
        fi
    else
        fail "test_drain_skip_exits_1: expected exit 1, got $RUN_EXIT"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 7. test_drain_done_story_id_targets_specific_story
# ---------------------------------------------------------------------------
test_drain_done_story_id_targets_specific_story() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local f
    f="$(_make_stories_file "$tmpdir" '[
      {"id":"A-id","title":"Story A","instructions":"Do A","verification_command":"exit 0","deps":[]},
      {"id":"B-id","title":"Story B","instructions":"Do B","verification_command":"exit 0","deps":[]}
    ]')"

    _run_drain "$f" "done A-id"

    if echo "$RUN_OUT" | grep -q "A-id"; then
        if echo "$RUN_OUT" | grep -qiE "B-id.*defer|defer.*B-id|B-id.*pending|skipping B-id|B-id.*later"; then
            pass "test_drain_done_story_id_targets_specific_story"
        else
            # Accept: A-id processed, B-id not mentioned as done
            if ! echo "$RUN_OUT" | grep -qE "B-id.*done|done.*B-id"; then
                pass "test_drain_done_story_id_targets_specific_story"
            else
                fail "test_drain_done_story_id_targets_specific_story: B-id should be deferred, not done"
            fi
        fi
    else
        fail "test_drain_done_story_id_targets_specific_story: A-id not mentioned in output (got: $RUN_OUT)"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 8. test_drain_confirmation_token_audit_comment
# ---------------------------------------------------------------------------
test_drain_confirmation_token_audit_comment() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local f
    f="$(_make_stories_file "$tmpdir" '[{"id":"st-008","title":"Token audit story","instructions":"Confirm with token","verification_command":null,"deps":[]}]')"

    # Two-line input: first line "done", second line the confirmation token
    _run_drain "$f" "$(printf 'done\nmytoken123')"

    if [[ "$RUN_EXIT" -eq 0 ]]; then
        if echo "$RUN_OUT" | grep -qiE "mytoken123|token|confirm"; then
            pass "test_drain_confirmation_token_audit_comment"
        else
            fail "test_drain_confirmation_token_audit_comment: output missing token/confirmation mention (got: $RUN_OUT)"
        fi
    else
        fail "test_drain_confirmation_token_audit_comment: expected exit 0, got $RUN_EXIT"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 9. test_drain_sentinel_written_format_valid
# ---------------------------------------------------------------------------
test_drain_sentinel_written_format_valid() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local f
    f="$(_make_stories_file "$tmpdir" '[{"id":"st-009","title":"Sentinel story","instructions":"Verify sentinel","verification_command":"exit 0","deps":[]}]')"

    _run_drain "$f" "done"

    # The mock dso records calls; look for a MANUAL_PAUSE_SENTINEL comment
    local mock_log="${RUN_TMPDIR}/dso-calls.log"
    local found_sentinel=false

    if [[ "$SCRIPT_MISSING" == "true" ]]; then
        fail "test_drain_sentinel_written_format_valid: script not found"
        rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
        return
    fi

    if [[ -f "$mock_log" ]]; then
        if grep -q "MANUAL_PAUSE_SENTINEL: " "$mock_log"; then
            # Extract the JSON portion and verify it is parseable
            local sentinel_line
            sentinel_line="$(grep "MANUAL_PAUSE_SENTINEL: " "$mock_log" | head -1)"
            local json_part="${sentinel_line#*MANUAL_PAUSE_SENTINEL: }"
            if echo "$json_part" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
                pass "test_drain_sentinel_written_format_valid"
            else
                fail "test_drain_sentinel_written_format_valid: sentinel JSON not parseable (got: $json_part)"
            fi
        else
            fail "test_drain_sentinel_written_format_valid: no MANUAL_PAUSE_SENTINEL comment recorded"
        fi
    else
        fail "test_drain_sentinel_written_format_valid: mock dso log not found (exit=$RUN_EXIT, out=$RUN_OUT)"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 10. test_drain_topo_sort_manual_stories_order_preserved
# ---------------------------------------------------------------------------
test_drain_topo_sort_manual_stories_order_preserved() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local f
    f="$(_make_stories_file "$tmpdir" '[
      {"id":"M1-id","title":"Story M1","instructions":"First step","verification_command":"exit 0","deps":[]},
      {"id":"M2-id","title":"Story M2","instructions":"Second step","verification_command":"exit 0","deps":[]}
    ]')"

    # Two "done" inputs, one per story
    _run_drain "$f" "$(printf 'done\ndone')"

    # M1 prompt must appear before M2 prompt in output
    local m1_pos m2_pos
    m1_pos="$(echo "$RUN_OUT" | grep -n "M1-id\|M1\|Story M1" | head -1 | cut -d: -f1)"
    m2_pos="$(echo "$RUN_OUT" | grep -n "M2-id\|M2\|Story M2" | head -1 | cut -d: -f1)"

    if [[ -z "$m1_pos" ]] || [[ -z "$m2_pos" ]]; then
        fail "test_drain_topo_sort_manual_stories_order_preserved: M1 or M2 not found in output (got: $RUN_OUT)"
    elif [[ "$m1_pos" -lt "$m2_pos" ]]; then
        pass "test_drain_topo_sort_manual_stories_order_preserved"
    else
        fail "test_drain_topo_sort_manual_stories_order_preserved: M1 (line $m1_pos) not before M2 (line $m2_pos)"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# 11. test_drain_cycle_detected_diagnostic
# ---------------------------------------------------------------------------
test_drain_cycle_detected_diagnostic() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    # Circular dependency: M1 depends on M2, M2 depends on M1
    local f
    f="$(_make_stories_file "$tmpdir" '[
      {"id":"M1-cycle","title":"Circular M1","instructions":"Step 1","verification_command":null,"deps":["M2-cycle"]},
      {"id":"M2-cycle","title":"Circular M2","instructions":"Step 2","verification_command":null,"deps":["M1-cycle"]}
    ]')"

    _run_drain "$f" "done"

    if [[ "$RUN_EXIT" -ne 0 ]]; then
        if echo "$RUN_OUT" | grep -qi "CYCLE_DETECTED"; then
            pass "test_drain_cycle_detected_diagnostic"
        else
            fail "test_drain_cycle_detected_diagnostic: non-zero exit but missing CYCLE_DETECTED (got: $RUN_OUT)"
        fi
    else
        fail "test_drain_cycle_detected_diagnostic: expected non-zero exit for cycle, got 0"
    fi
    rm -rf "$tmpdir" "${RUN_TMPDIR:-}"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_drain_done_runs_verification_command_exit_0_proceeds
test_drain_done_re_prompts_on_verification_command_fail
test_drain_done_re_prompts_on_timeout
test_drain_dangerous_pattern_rejected
test_drain_oversize_command_rejected
test_drain_skip_exits_1
test_drain_done_story_id_targets_specific_story
test_drain_confirmation_token_audit_comment
test_drain_sentinel_written_format_valid
test_drain_topo_sort_manual_stories_order_preserved
test_drain_cycle_detected_diagnostic

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
TOTAL=$((PASS + FAIL))
echo "=== Results: ${PASS}/${TOTAL} passed ==="
if (( FAIL > 0 )); then
    echo "FAILED: ${FAIL} test(s) failed"
    exit 1
else
    echo "All tests passed."
    exit 0
fi
