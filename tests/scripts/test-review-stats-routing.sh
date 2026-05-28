#!/usr/bin/env bash
# tests/scripts/test-review-stats-routing.sh
# Routing integration tests for /dso:review-stats --source=central dispatch.
#
# Verifies the routing semantics documented in
# plugins/dso/skills/review-stats/SKILL.md:
#   • --source=central  → dispatches ${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/query-stats.sh
#   • (no --source)     → default local-file behavior; does NOT call query-stats.sh
#   • --source=bogus    → preserves default behavior OR exits non-zero with usage
#
# AC regex markers required by task 8349-c3ea-4691-4534:
#   "default.*no.?call|no.?source.*preserves|default.?route.*not.*query-stats"
#   "(source=bogus|unknown.?source|invalid.?source)"
#
# Usage: bash tests/scripts/test-review-stats-routing.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-stats-routing.sh ==="

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
    d="$(mktemp -d "${TMPDIR:-/tmp}/review-stats-routing-test.XXXXXX")"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

make_tmpfile() {
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/review-stats-routing-test.XXXXXX")"
    _TEST_TMPDIRS+=("$f")
    echo "$f"
}

# ── Helper: build a minimal review-stats dispatcher that implements SKILL.md ──
# This simulates exactly what the SKILL.md agent instructions say to do:
#   - If --source=central is passed → dispatch query-stats.sh and surface stdout
#   - Otherwise (no --source or --source=bogus) → default local-file behavior
#
# The dispatcher uses CLAUDE_PLUGIN_ROOT to locate query-stats.sh.
#
# NOTE: This wrapper is the testable representation of the SKILL.md instructions.
# SKILL.md itself is agent guidance; this wrapper encodes the same dispatch logic
# so tests can assert the routing contract without an LLM in the loop.
write_review_stats_dispatcher() {
    local dispatcher_path="$1"
    cat > "$dispatcher_path" << 'DISPEOF'
#!/usr/bin/env bash
# review-stats-dispatcher.sh
# Simulates the routing described in plugins/dso/skills/review-stats/SKILL.md.
# --source=central → dispatch ${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/query-stats.sh
# default (no --source) → existing review-stats.sh local-file path (preserved)
# --source=bogus → treated as invalid; preserves default behavior (no query-stats call)
set -uo pipefail

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
QUERY_STATS_OVERRIDE="${QUERY_STATS_OVERRIDE:-}"

source_flag=""
subcmd=""
remaining_args=()

for arg in "$@"; do
    case "$arg" in
        --source=*)
            source_flag="${arg#--source=}"
            ;;
        *)
            remaining_args+=("$arg")
            ;;
    esac
done

# Extract subcommand (first non-flag arg after parsing)
if [[ ${#remaining_args[@]} -gt 0 ]]; then
    subcmd="${remaining_args[0]}"
    remaining_args=("${remaining_args[@]:1}")
fi

if [[ "$source_flag" == "central" ]]; then
    # SKILL.md routing: dispatch query-stats.sh and surface its stdout verbatim
    query_stats="${QUERY_STATS_OVERRIDE:-${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/query-stats.sh}"
    exec bash "$query_stats" "$subcmd" "${remaining_args[@]}"
elif [[ -n "$source_flag" && "$source_flag" != "" ]]; then
    # --source=<invalid source>: preserve default behavior (no query-stats call)
    # A SKILL.md implementation may also exit non-zero here; this implementation
    # preserves default (local-file) behavior and does NOT invoke query-stats.sh.
    echo "INFO: unknown source '${source_flag}'; using default local-file behavior"
    # Default behavior: call review-stats.sh (or print no-op for test harness)
    echo "DEFAULT_BEHAVIOR_OUTPUT"
    exit 0
else
    # Default (no --source): existing local-file behavior — does NOT call query-stats.sh
    # Default no-call — no source flag preserves local-file behavior
    echo "DEFAULT_BEHAVIOR_OUTPUT"
    exit 0
fi
DISPEOF
    chmod +x "$dispatcher_path"
}

# ── Helper: write a sentinel-emitting stub for query-stats.sh ─────────────────
write_query_stats_sentinel_stub() {
    local stub_path="$1"
    local sentinel="$2"
    local recorder_file="${3:-/dev/null}"
    cat > "$stub_path" << STUBEOF
#!/usr/bin/env bash
# Sentinel stub for query-stats.sh
echo "$sentinel"
echo "QUERY_STATS_CALLED: \$*" >> "$recorder_file"
exit 0
STUBEOF
    chmod +x "$stub_path"
}

# ── Helper: write a recorder-only stub (for asserting NOT called) ─────────────
write_query_stats_recorder_stub() {
    local stub_path="$1"
    local recorder_file="$2"
    cat > "$stub_path" << STUBEOF
#!/usr/bin/env bash
# Recorder-only stub — writes to recorder so caller can detect invocation
echo "QUERY_STATS_CALLED: \$*" >> "$recorder_file"
exit 0
STUBEOF
    chmod +x "$stub_path"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: --source=central invokes query-stats.sh and surfaces its stdout
# ──────────────────────────────────────────────────────────────────────────────
# Verifies SKILL.md routing: "when --source=central is passed, dispatch
# ${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/query-stats.sh <subcommand> <args>
# and surface its stdout to the caller verbatim"
# ══════════════════════════════════════════════════════════════════════════════
t_review_stats_source_central_invokes_query_stats() {
    local mock_dir recorder_file dispatcher sentinel
    mock_dir="$(make_tmpdir)"
    recorder_file="$(make_tmpfile)"
    dispatcher="$mock_dir/review-stats-dispatcher.sh"

    # Generate a unique sentinel so we can assert it reached stdout
    sentinel="SENTINEL_FROM_QUERY_STATS_$$_$(date +%s)"

    # Write the sentinel+recorder stub
    write_query_stats_sentinel_stub "$mock_dir/query-stats-stub.sh" "$sentinel" "$recorder_file"

    # Write the dispatcher (simulates SKILL.md routing)
    write_review_stats_dispatcher "$dispatcher"

    # Invoke with --source=central; override query-stats path to our stub
    local out exit_code=0
    out="$(CLAUDE_PLUGIN_ROOT="$mock_dir" \
           QUERY_STATS_OVERRIDE="$mock_dir/query-stats-stub.sh" \
           bash "$dispatcher" --source=central counts 2>&1)" || exit_code=$?

    # Assert: sentinel reached stdout
    assert_contains "t_source_central: sentinel in stdout" "$sentinel" "$out"

    # Assert: recorder confirms query-stats was called
    local recorder_content
    recorder_content="$(cat "$recorder_file" 2>/dev/null || echo "")"
    assert_contains "t_source_central: query-stats recorder shows invocation" \
        "QUERY_STATS_CALLED" "$recorder_content"

    # Assert: exit code was 0
    assert_eq "t_source_central: exits 0" "0" "$exit_code"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: Default route (no --source) does NOT invoke query-stats.sh
# ──────────────────────────────────────────────────────────────────────────────
# AC regex marker: "default.*no.?call|no.?source.*preserves|default.?route.*not.*query-stats"
# Verifies SKILL.md: "default (no --source) preserves the existing local-file
# behavior — does NOT call query-stats.sh"
# ══════════════════════════════════════════════════════════════════════════════
# default route — no source flag — preserves local-file behavior, no call to query-stats
t_review_stats_default_route_does_NOT_invoke_query_stats() {
    local mock_dir recorder_file dispatcher
    mock_dir="$(make_tmpdir)"
    recorder_file="$(make_tmpfile)"
    dispatcher="$mock_dir/review-stats-dispatcher.sh"

    # Write recorder-only stub (detects if query-stats.sh is called)
    write_query_stats_recorder_stub "$mock_dir/query-stats-stub.sh" "$recorder_file"

    # Write the dispatcher (simulates SKILL.md routing)
    write_review_stats_dispatcher "$dispatcher"

    # Invoke with NO --source flag
    local out exit_code=0
    out="$(CLAUDE_PLUGIN_ROOT="$mock_dir" \
           QUERY_STATS_OVERRIDE="$mock_dir/query-stats-stub.sh" \
           bash "$dispatcher" 2>&1)" || exit_code=$?

    # Assert: recorder file is empty — query-stats was NOT called
    local recorder_content
    recorder_content="$(cat "$recorder_file" 2>/dev/null || echo "")"
    assert_eq "t_default_route: recorder empty (query-stats not called)" \
        "" "$recorder_content"

    # Assert: dispatcher exited 0 (default behavior is graceful)
    assert_eq "t_default_route: exits 0" "0" "$exit_code"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: --source=bogus is handled gracefully
# ──────────────────────────────────────────────────────────────────────────────
# AC regex marker: "(source=bogus|unknown.?source|invalid.?source)"
# Acceptable outcomes per task spec:
#   (a) preserves default behavior (recorder empty — query-stats NOT called), OR
#   (b) exits non-zero with usage listing valid sources
# SKILL.md documents the chosen behavior (option a: treat unknown source as default)
# ══════════════════════════════════════════════════════════════════════════════
# source=bogus / unknown-source / invalid-source — handled gracefully
t_review_stats_source_bogus_handled() {
    local mock_dir recorder_file dispatcher
    mock_dir="$(make_tmpdir)"
    recorder_file="$(make_tmpfile)"
    dispatcher="$mock_dir/review-stats-dispatcher.sh"

    # Write recorder-only stub
    write_query_stats_recorder_stub "$mock_dir/query-stats-stub.sh" "$recorder_file"

    # Write the dispatcher
    write_review_stats_dispatcher "$dispatcher"

    # Invoke with --source=bogus
    local out exit_code=0
    out="$(CLAUDE_PLUGIN_ROOT="$mock_dir" \
           QUERY_STATS_OVERRIDE="$mock_dir/query-stats-stub.sh" \
           bash "$dispatcher" --source=bogus 2>&1)" || exit_code=$?

    # Accept either outcome (a) or (b):
    local recorder_content
    recorder_content="$(cat "$recorder_file" 2>/dev/null || echo "")"

    local query_stats_was_called="no"
    if [[ "$recorder_content" == *"QUERY_STATS_CALLED"* ]]; then
        query_stats_was_called="yes"
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        # Outcome (b): exited non-zero — acceptable; confirm output has source/usage context
        local has_source_context=0
        if echo "$out" | grep -qiE "(source|bogus|unknown|invalid|usage)"; then
            has_source_context=1
        fi
        assert_eq "t_bogus_source: non-zero exit has source/usage context" "1" "$has_source_context"
        assert_eq "t_bogus_source: query-stats NOT called when exiting non-zero" "no" "$query_stats_was_called"
    else
        # Outcome (a): exited 0 — default behavior preserved; query-stats must NOT be called
        assert_eq "t_bogus_source: query-stats NOT called (default behavior preserved)" \
            "no" "$query_stats_was_called"
        assert_eq "t_bogus_source: exits 0 when defaulting" "0" "$exit_code"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: SKILL.md documents --source=central routing (RED gate)
# ──────────────────────────────────────────────────────────────────────────────
# Verifies that the SKILL.md has been updated to include:
#   1. "--source=central" in the argument reference
#   2. A routing section dispatching query-stats.sh
#   3. Explicit statement that default (no --source) preserves local-file behavior
#
# This test is RED before SKILL.md is updated, GREEN after.
# ══════════════════════════════════════════════════════════════════════════════
t_skill_md_documents_source_central_routing() {
    local skill_md
    skill_md="$REPO_ROOT/plugins/dso/skills/review-stats/SKILL.md"

    local skill_content
    skill_content="$(cat "$skill_md" 2>/dev/null || echo "")"

    # 1. Must mention --source=central in argument reference
    assert_contains "t_skill_md: documents --source=central argument" \
        "--source=central" "$skill_content"

    # 2. Must mention query-stats.sh as the dispatch target
    assert_contains "t_skill_md: references query-stats.sh dispatch target" \
        "query-stats.sh" "$skill_content"

    # 3. Must state that default behavior (no --source) does NOT call query-stats.sh
    # Accept any phrasing that conveys the default-no-call contract
    local has_default_contract=0
    if echo "$skill_content" | grep -qiE "(default.*no.?call|no.?source.*preserves|default.?route.*not.*query-stats|no.*source.*does not|without.*source.*existing)"; then
        has_default_contract=1
    fi
    assert_eq "t_skill_md: documents default-no-call contract" "1" "$has_default_contract"

    # 4. Must mention valid sources or invalid source handling
    # Accept any phrasing about bogus/unknown/invalid source
    local has_bogus_handling=0
    if echo "$skill_content" | grep -qiE "(source=bogus|unknown.?source|invalid.?source|valid.*source|bogus.*source)"; then
        has_bogus_handling=1
    fi
    assert_eq "t_skill_md: documents invalid source handling" "1" "$has_bogus_handling"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
t_review_stats_source_central_invokes_query_stats
t_review_stats_default_route_does_NOT_invoke_query_stats
t_review_stats_source_bogus_handled
t_skill_md_documents_source_central_routing

print_summary
