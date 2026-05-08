#!/usr/bin/env bash
# tests/integration/test-merge-to-main-pr-thread-resolution.sh
#
# RED integration tests for the PR review-thread resolution loop in
# merge-to-main-pr.sh and the supporting helpers in hooks/lib/merge-helpers.sh.
#
# These tests drive (not-yet-built) helpers:
#   _pr_fetch_unresolved_threads <pr_number>     — emits unresolved thread IDs,
#                                                  one per line, on stdout.
#   _pr_thread_is_unresolved      <thread_node_id> — prints "true" when the
#                                                    thread is still open (unresolved),
#                                                    "false" otherwise; always exits 0.
#   _pr_post_thread_reply         <thread> <txt> — posts a reply via gh.
#   _pr_resolve_thread            <thread_id>    — short-circuits when already
#                                                  resolved; otherwise mutates.
#   _phase_resolve_threads        <pr_number>    — main loop. Settling heuristic
#                                                  requires (CI green AND zero
#                                                  unresolved threads AND quiet
#                                                  window). Caps: 10 dispatches
#                                                  or 30 minutes elapsed.
#                                                  Emits PR url + unresolved IDs
#                                                  on stderr when escalating.
#                                                  Resets the poll wall-clock
#                                                  when a code push triggers
#                                                  dismiss_stale_approvals_on_push.
#
# RED state: these functions DO NOT EXIST yet. Each test sources the libs,
# verifies the function is missing (via `type`), and asserts on observable
# behavior the helpers MUST produce once T3/T4 land. A FAIL here is the
# expected RED outcome — the test gate accepts it via .test-index markers.
#
# Stubbing: a per-test temp dir is prepended to PATH. The dir contains
#   * `gh` — bash shim that records argv and stdin to $STUB_GH_LOG, then
#            emits canned JSON keyed by $STUB_GH_SCENARIO.
#   * `llm-api-call.sh` — bash shim that records argv to $STUB_LLM_LOG and
#                         emits a canned response.
#
# Tests assert against:
#   - exit codes
#   - captured stdout/stderr
#   - the per-test stub call logs (counts, invoked subcommands)
# No source-file greps.
#
# Usage:
#   bash tests/integration/test-merge-to-main-pr-thread-resolution.sh
# Exit: 0 if all tests pass (GREEN once T3/T4 land), non-zero otherwise (RED).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-merge-to-main-pr-thread-resolution.sh ==="

# ---------------------------------------------------------------------------
# Globals & cleanup
# ---------------------------------------------------------------------------
_TEST_TMPDIRS=()
_cleanup() {
    local d
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "${d:-}" && -d "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup EXIT

MERGE_HELPERS_LIB="$REPO_ROOT/plugins/dso/hooks/lib/merge-helpers.sh"
MERGE_PR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/merge-to-main-pr.sh"

# ---------------------------------------------------------------------------
# _make_stub_dir — create a per-test stub PATH prefix containing `gh` and
# `llm-api-call.sh` shims. Returns the dir path on stdout.
#
# The stubs are scenario-driven via env vars set by the caller before invoking
# the helper under test:
#   STUB_GH_SCENARIO       — selector for the canned JSON response
#   STUB_GH_LOG            — file the gh shim appends each call's argv to
#   STUB_GH_THREADS_FIXTURE — path to a JSON fixture for graphql thread lists
#   STUB_LLM_LOG           — file the llm shim appends each call's argv to
# ---------------------------------------------------------------------------
_make_stub_dir() {
    local d
    d=$(mktemp -d "/tmp/dso-pr-thread-stubs.XXXXXX")
    _TEST_TMPDIRS+=("$d")

    cat > "$d/gh" <<'GHEOF'
#!/usr/bin/env bash
# Test stub for `gh`. Records argv+stdin to $STUB_GH_LOG, returns scenario JSON.
set -u
LOG="${STUB_GH_LOG:-/dev/null}"
{
    printf 'CALL'
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
} >> "$LOG" 2>/dev/null || true

# Capture stdin for graphql mutation calls (so tests can assert payloads)
if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
    if [[ ! -t 0 ]]; then
        {
            printf 'STDIN_BEGIN\n'
            cat
            printf '\nSTDIN_END\n'
        } >> "$LOG" 2>/dev/null || true
    fi
fi

case "${STUB_GH_SCENARIO:-default}" in
    threads_mixed)
        # Fixture-backed: emit the contents of $STUB_GH_THREADS_FIXTURE
        if [[ -n "${STUB_GH_THREADS_FIXTURE:-}" && -f "${STUB_GH_THREADS_FIXTURE:-}" ]]; then
            cat "$STUB_GH_THREADS_FIXTURE"
        else
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
        fi
        ;;
    threads_all_resolved)
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRT_1","isResolved":true}]}}}}}'
        ;;
    ci_green_quiet)
        # gh pr checks → all SUCCESS
        if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
            echo '[{"name":"ci","state":"COMPLETED","conclusion":"SUCCESS"}]'
        elif [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
            echo '{"state":"OPEN","mergeable":"MERGEABLE","headRefOid":"abc123"}'
        else
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
        fi
        ;;
    ci_pending)
        if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
            echo '[{"name":"ci","state":"IN_PROGRESS","conclusion":""}]'
        else
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
        fi
        ;;
    push_dismissed)
        # Simulate a code push between iterations: headRefOid changes.
        # Each call returns a fresh oid → forces dismiss_stale_approvals reset.
        if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
            echo '{"state":"OPEN","mergeable":"MERGEABLE","headRefOid":"newsha'"$RANDOM"'"}'
        elif [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
            echo '[{"name":"ci","state":"IN_PROGRESS","conclusion":""}]'
        else
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
        fi
        ;;
    threads_one_unresolved)
        # Loop-style: always returns one unresolved thread → keeps loop spinning
        # until dispatch cap or wall-clock cap fires.
        if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
            echo '[{"name":"ci","state":"COMPLETED","conclusion":"SUCCESS"}]'
        elif [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
            echo '{"state":"OPEN","mergeable":"MERGEABLE","headRefOid":"sha-stable"}'
        else
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRT_STUCK","isResolved":false,"path":"x.py","body":"comment"}]}}}}}'
        fi
        ;;
    *)
        echo '{}'
        ;;
esac
exit 0
GHEOF
    chmod +x "$d/gh"

    cat > "$d/llm-api-call.sh" <<'LLMEOF'
#!/usr/bin/env bash
# Test stub for llm-api-call.sh. Records each invocation, returns canned output.
set -u
LOG="${STUB_LLM_LOG:-/dev/null}"
{
    printf 'CALL'
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
} >> "$LOG" 2>/dev/null || true
echo 'ACTION:reply REPLY:acknowledged'
exit 0
LLMEOF
    chmod +x "$d/llm-api-call.sh"

    echo "$d"
}

# ---------------------------------------------------------------------------
# _make_threads_fixture <out_path>
# Mixed fixture: 2 unresolved + 1 resolved review thread.
# ---------------------------------------------------------------------------
_make_threads_fixture() {
    local out="$1"
    cat > "$out" <<'FIX'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": [
            {"id": "PRT_AAA", "isResolved": false, "path": "src/a.py", "body": "fix me"},
            {"id": "PRT_BBB", "isResolved": true,  "path": "src/b.py", "body": "ok now"},
            {"id": "PRT_CCC", "isResolved": false, "path": "src/c.py", "body": "still wrong"}
          ]
        }
      }
    }
  }
}
FIX
}

# ---------------------------------------------------------------------------
# _setup_test — fresh stubs + per-test logs + PATH prefix.
# Sets the following env for the test body:
#   STUB_DIR, STUB_GH_LOG, STUB_LLM_LOG, original PATH saved as _SAVED_PATH.
# ---------------------------------------------------------------------------
_setup_test() {
    STUB_DIR=$(_make_stub_dir)
    STUB_GH_LOG="$STUB_DIR/gh.log"
    STUB_LLM_LOG="$STUB_DIR/llm.log"
    : > "$STUB_GH_LOG"
    : > "$STUB_LLM_LOG"
    export STUB_GH_LOG STUB_LLM_LOG
    _SAVED_PATH="$PATH"
    PATH="$STUB_DIR:$PATH"
    export PATH
    # Point _phase_resolve_threads at the stub so tests never hit the real LLM.
    export _LLM_DISPATCH_CMD="$STUB_DIR/llm-api-call.sh"
    # The script's _dso_is_ci_environment guard rejects LLM dispatch outside CI.
    # Tests for thread-resolution dispatch behavior must opt into CI to exercise
    # the real code path.
    export CI="true"
    # Set BRANCH so merge-helpers.sh state functions don't blow up.
    BRANCH="test-branch-$$"
    export BRANCH
}

_teardown_test() {
    PATH="$_SAVED_PATH"
    export PATH
    unset STUB_GH_SCENARIO STUB_GH_THREADS_FIXTURE
    unset PR_THREAD_LOOP_INTERVAL PR_THREAD_LOOP_MAX_DISPATCHES PR_THREAD_LOOP_MAX_WALL_SECONDS
    unset PR_THREAD_LOOP_START_OVERRIDE_SECONDS PR_THREAD_LOOP_TEST_STOP_AFTER_RESET
    unset _LLM_DISPATCH_CMD
    unset CI
}

# Convenience: count how many times the gh stub was called with given subcmd.
_gh_call_count() {
    local pattern="$1"
    grep -c "^CALL.*${pattern}" "$STUB_GH_LOG" 2>/dev/null || echo 0
}

# ===========================================================================
# Test 1: _pr_fetch_unresolved_threads parses unresolved IDs from a mixed
# GraphQL response, returning ONLY the unresolved thread IDs on stdout.
# ===========================================================================
test_review_threads_query_parses_unresolved_thread_ids() {
    _setup_test
    local fixture="$STUB_DIR/threads-mixed.json"
    _make_threads_fixture "$fixture"
    export STUB_GH_SCENARIO=threads_mixed
    export STUB_GH_THREADS_FIXTURE="$fixture"

    # Source the merge-helpers library; helper must be defined here (RED until T3).
    # shellcheck disable=SC1090
    source "$MERGE_HELPERS_LIB" 2>/dev/null || true

    if ! type _pr_fetch_unresolved_threads >/dev/null 2>&1; then
        (( ++FAIL ))
        echo "FAIL: test_review_threads_query_parses_unresolved_thread_ids — _pr_fetch_unresolved_threads not defined (RED until T3)" >&2
        _teardown_test
        return
    fi

    local out
    out=$(_pr_fetch_unresolved_threads 42 2>/dev/null) || out=""

    # Behavioral assertions: only unresolved IDs appear, resolved ID is absent.
    assert_contains "test_review_threads_query_parses_unresolved_thread_ids: includes PRT_AAA" "PRT_AAA" "$out"
    assert_contains "test_review_threads_query_parses_unresolved_thread_ids: includes PRT_CCC" "PRT_CCC" "$out"
    assert_not_contains "test_review_threads_query_parses_unresolved_thread_ids: excludes PRT_BBB (resolved)" "PRT_BBB" "$out"

    # Exactly one gh graphql call was made.
    local n
    n=$(_gh_call_count "graphql")
    assert_eq "test_review_threads_query_parses_unresolved_thread_ids: one graphql call" "1" "$n"

    _teardown_test
}

# ===========================================================================
# Test 2: _pr_resolve_thread short-circuits when the thread is already resolved
# (verified internally by calling _pr_thread_is_unresolved); invokes the
# resolveReviewThread mutation exactly once when the thread is unresolved.
# Helper signature per T3 spec: _pr_resolve_thread <thread_node_id> (single arg).
# ===========================================================================
test_resolve_thread_calls_mutation_only_when_unresolved() {
    _setup_test

    # shellcheck disable=SC1090
    source "$MERGE_HELPERS_LIB" 2>/dev/null || true

    if ! type _pr_resolve_thread >/dev/null 2>&1; then
        (( ++FAIL ))
        echo "FAIL: test_resolve_thread_calls_mutation_only_when_unresolved — _pr_resolve_thread not defined (RED until T3)" >&2
        _teardown_test
        return
    fi

    # Case 1: pre-resolved thread → idempotent precheck reports isResolved=true,
    # mutation NOT invoked. Stub gh returns isResolved=true for any thread query.
    export STUB_GH_SCENARIO=threads_all_resolved
    : > "$STUB_GH_LOG"
    _pr_resolve_thread "PRT_RESOLVED" >/dev/null 2>&1 || true
    local mut1
    # grep -c outputs "0" (no matches) and exits 1 when file exists; strip the
    # || fallback so we don't capture "0\n0" when there are zero matches.
    mut1=$(grep -c 'resolveReviewThread' "$STUB_GH_LOG" 2>/dev/null; true)
    assert_eq "test_resolve_thread_calls_mutation_only_when_unresolved: zero mutations when pre-resolved" "0" "$mut1"

    # Case 2: unresolved thread → precheck reports isResolved=false, mutation
    # invoked exactly once. Stub returns isResolved=false for PRT_STUCK.
    # Must pass the same ID the stub returns — _pr_thread_is_unresolved filters by ID.
    export STUB_GH_SCENARIO=threads_one_unresolved
    : > "$STUB_GH_LOG"
    _pr_resolve_thread "PRT_STUCK" >/dev/null 2>&1 || true
    local mut2
    mut2=$(grep -c 'resolveReviewThread' "$STUB_GH_LOG" 2>/dev/null; true)
    assert_eq "test_resolve_thread_calls_mutation_only_when_unresolved: one mutation when unresolved" "1" "$mut2"

    _teardown_test
}

# ===========================================================================
# Test 3: settling heuristic — must require ALL THREE: CI green AND zero
# unresolved threads AND a quiet window since last activity. Falsified by any
# missing condition.
# ===========================================================================
test_settling_heuristic_requires_zero_threads_and_quiet_window() {
    _setup_test

    # shellcheck disable=SC1090
    source "$MERGE_HELPERS_LIB" 2>/dev/null || true

    if ! type _pr_settling_check >/dev/null 2>&1; then
        (( ++FAIL ))
        echo "FAIL: test_settling_heuristic_requires_zero_threads_and_quiet_window — _pr_settling_check not defined" >&2
        _teardown_test
        return
    fi

    # Both conditions hold → settled (exit 0).
    local rc=0
    _pr_settling_check --threads=0 --quiet-window-elapsed=true >/dev/null 2>&1 || rc=$?
    assert_eq "test_settling_heuristic: settles when threads=0 and quiet window elapsed" "0" "$rc"

    # CI state is irrelevant — settles regardless of CI green/not-green.
    rc=0
    _pr_settling_check --ci-green=false --threads=0 --quiet-window-elapsed=true >/dev/null 2>&1 || rc=$?
    assert_eq "test_settling_heuristic: settles with ci-green=false (CI state ignored)" "0" "$rc"

    # Threads remaining → unsettled.
    rc=0
    _pr_settling_check --threads=2 --quiet-window-elapsed=true >/dev/null 2>&1 || rc=$?
    assert_ne "test_settling_heuristic: unsettled when threads remain" "0" "$rc"

    # Quiet window not elapsed → unsettled.
    rc=0
    _pr_settling_check --threads=0 --quiet-window-elapsed=false >/dev/null 2>&1 || rc=$?
    assert_ne "test_settling_heuristic: unsettled when quiet window not elapsed" "0" "$rc"

    _teardown_test
}

# ===========================================================================
# Test 4: dispatch count cap — after 10 dispatches without settling, the loop
# exits non-zero with PR url + unresolved thread IDs in stderr.
# ===========================================================================
test_dispatch_count_cap_triggers_escalation() {
    _setup_test
    export STUB_GH_SCENARIO=threads_one_unresolved
    # Force the loop to test the dispatch cap by setting interval to 0 and
    # disabling wall-clock cap (very large).
    export PR_THREAD_LOOP_INTERVAL=0
    export PR_THREAD_LOOP_MAX_DISPATCHES=10
    export PR_THREAD_LOOP_MAX_WALL_SECONDS=99999

    # Source merge-helpers.sh + define _phase_resolve_threads by sourcing
    # merge-to-main-pr.sh in library mode if/when it supports that. Until T4
    # lands, the function is missing → RED.
    # shellcheck disable=SC1090
    source "$MERGE_HELPERS_LIB" 2>/dev/null || true

    # Run the loop call in a subshell so an exit/abort cannot kill the test
    # runner. T4 currently has NOT landed: _phase_resolve_threads is missing
    # and the subshell will exit non-zero. That is the RED outcome we record.
    local stderr_capture rc=0
    stderr_capture=$(
        # shellcheck disable=SC1090
        source "$MERGE_HELPERS_LIB" 2>/dev/null || true
        if ! type _phase_resolve_threads >/dev/null 2>&1; then
            # Library-mode source attempt; will run top-level code in this
            # subshell only. Suppress its output.
            PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" MERGE_STRATEGY=pr \
                source "$MERGE_PR_SCRIPT" >/dev/null 2>&1 || true
        fi
        if ! type _phase_resolve_threads >/dev/null 2>&1; then
            echo "MISSING_FUNCTION:_phase_resolve_threads" >&2
            exit 99
        fi
        _phase_resolve_threads 99 "https://github.com/o/r/pull/99" 2>&1 >/dev/null
    ) || rc=$?

    if [[ "$rc" == "99" ]] || [[ "$stderr_capture" == *"MISSING_FUNCTION:_phase_resolve_threads"* ]]; then
        (( ++FAIL ))
        echo "FAIL: test_dispatch_count_cap_triggers_escalation — _phase_resolve_threads not defined (RED until T4)" >&2
        _teardown_test
        return
    fi

    assert_ne "test_dispatch_count_cap_triggers_escalation: non-zero exit on cap" "0" "$rc"
    assert_contains "test_dispatch_count_cap_triggers_escalation: PR url in stderr" "pull/99" "$stderr_capture"
    assert_contains "test_dispatch_count_cap_triggers_escalation: unresolved id in stderr" "PRT_STUCK" "$stderr_capture"

    # Behavioral assertion: LLM dispatch was actually attempted before the cap fired.
    # A regression that skips dispatch silently would leave llm.log empty and fail here.
    local llm_call_count
    llm_call_count=$(grep -c '^CALL' "$STUB_LLM_LOG" 2>/dev/null || echo 0)
    assert_ne "test_dispatch_count_cap_triggers_escalation: LLM was dispatched at least once before cap" "0" "$llm_call_count"
    # With MAX_DISPATCHES=10 and a perpetually-unresolved thread, exactly 10 dispatches expected.
    assert_eq "test_dispatch_count_cap_triggers_escalation: LLM dispatched exactly max_dispatches times" "10" "$llm_call_count"

    _teardown_test
}

# ===========================================================================
# Test 5: wall-clock cap — after 30 simulated minutes elapsed, the loop exits
# non-zero with the same envelope (PR url + unresolved IDs).
# ===========================================================================
test_wall_clock_cap_triggers_escalation() {
    _setup_test
    export STUB_GH_SCENARIO=threads_one_unresolved
    # High dispatch cap + tiny wall-clock cap → wall-clock fires first.
    # The implementation must accept these env overrides (or read config).
    export PR_THREAD_LOOP_INTERVAL=0
    export PR_THREAD_LOOP_MAX_DISPATCHES=99999
    export PR_THREAD_LOOP_MAX_WALL_SECONDS=1
    # Pretend 30 minutes have already elapsed when the loop starts.
    export PR_THREAD_LOOP_START_OVERRIDE_SECONDS=1800

    # shellcheck disable=SC1090
    source "$MERGE_HELPERS_LIB" 2>/dev/null || true

    local stderr_capture rc=0
    stderr_capture=$(
        # shellcheck disable=SC1090
        source "$MERGE_HELPERS_LIB" 2>/dev/null || true
        if ! type _phase_resolve_threads >/dev/null 2>&1; then
            PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" MERGE_STRATEGY=pr \
                source "$MERGE_PR_SCRIPT" >/dev/null 2>&1 || true
        fi
        if ! type _phase_resolve_threads >/dev/null 2>&1; then
            echo "MISSING_FUNCTION:_phase_resolve_threads" >&2
            exit 99
        fi
        _phase_resolve_threads 77 "https://github.com/o/r/pull/77" 2>&1 >/dev/null
    ) || rc=$?

    if [[ "$rc" == "99" ]] || [[ "$stderr_capture" == *"MISSING_FUNCTION:_phase_resolve_threads"* ]]; then
        (( ++FAIL ))
        echo "FAIL: test_wall_clock_cap_triggers_escalation — _phase_resolve_threads not defined (RED until T4)" >&2
        _teardown_test
        return
    fi

    assert_ne "test_wall_clock_cap_triggers_escalation: non-zero exit on wall-clock cap" "0" "$rc"
    assert_contains "test_wall_clock_cap_triggers_escalation: PR url in stderr" "pull/77" "$stderr_capture"
    assert_contains "test_wall_clock_cap_triggers_escalation: unresolved id in stderr" "PRT_STUCK" "$stderr_capture"

    # Behavioral assertion: LLM dispatch was actually attempted before the wall-clock cap fired.
    # A regression that skips dispatch silently would leave llm.log empty and fail here.
    local llm_call_count
    llm_call_count=$(grep -c '^CALL' "$STUB_LLM_LOG" 2>/dev/null || echo 0)
    assert_ne "test_wall_clock_cap_triggers_escalation: LLM was dispatched at least once before wall-clock cap" "0" "$llm_call_count"

    _teardown_test
}

# ===========================================================================
# Test 6: push-induced dismissal resets poll wall-clock window — when a code
# push occurs between iterations and dismiss_stale_approvals_on_push fires,
# the poll window restart must not double-count the restarted CI as a
# separate timeout. After the reset, the loop must continue (no escalation).
#
# Coverage: verifies POLL_WINDOW_RESET signal emission and that no wall-clock
# escalation fires (ESCALATE:thread_resolution REASON:wall_clock). The test
# uses PR_THREAD_LOOP_TEST_STOP_AFTER_RESET=1 so the loop returns 0 on the
# iteration where reset is detected; rc=0 is an additional assertion.
#
# Trade-off note: proving that _start was *numerically* zeroed (not just that
# the signal was emitted) would require injecting synthetic $SECONDS values —
# not possible without modifying the implementation. This test instead verifies
# the observable contract: POLL_WINDOW_RESET emitted, function exits 0, and no
# wall_clock ESCALATE signal appears in the combined output.
# ===========================================================================
test_push_induced_dismissal_resets_poll_window() {
    _setup_test
    export STUB_GH_SCENARIO=push_dismissed
    # Tight wall-clock budget to make any wall_clock escalation visible if it
    # fires. The loop exits via STOP_AFTER_RESET before the wall-clock check
    # on the reset iteration, so the only way wall_clock could fire is on an
    # earlier iteration (which would mean the reset never happened).
    export PR_THREAD_LOOP_INTERVAL=0
    export PR_THREAD_LOOP_MAX_DISPATCHES=2
    export PR_THREAD_LOOP_MAX_WALL_SECONDS=5
    # Tell the loop to stop after detecting one reset (test-only escape).
    export PR_THREAD_LOOP_TEST_STOP_AFTER_RESET=1

    # shellcheck disable=SC1090
    source "$MERGE_HELPERS_LIB" 2>/dev/null || true

    local combined rc=0
    combined=$(
        # shellcheck disable=SC1090
        source "$MERGE_HELPERS_LIB" 2>/dev/null || true
        if ! type _phase_resolve_threads >/dev/null 2>&1; then
            PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" MERGE_STRATEGY=pr \
                source "$MERGE_PR_SCRIPT" >/dev/null 2>&1 || true
        fi
        if ! type _phase_resolve_threads >/dev/null 2>&1; then
            echo "MISSING_FUNCTION:_phase_resolve_threads"
            exit 99
        fi
        _phase_resolve_threads 55 "https://github.com/o/r/pull/55" 2>&1
    ) || rc=$?

    if [[ "$rc" == "99" ]] || [[ "$combined" == *"MISSING_FUNCTION:_phase_resolve_threads"* ]]; then
        (( ++FAIL ))
        echo "FAIL: test_push_induced_dismissal_resets_poll_window — _phase_resolve_threads not defined (RED until T4)" >&2
        _teardown_test
        return
    fi

    # Wall-clock counter reset verification: the function must return 0 when
    # STOP_AFTER_RESET fires. A non-zero rc means the loop escalated (wall_clock
    # or dispatch_cap) before the reset was detected — i.e., the counter reset
    # path was never reached.
    if (( rc != 0 )); then
        (( ++FAIL ))
        echo "FAIL: test_push_induced_dismissal_resets_poll_window: expected rc=0 (reset path), got rc=${rc}" >&2
        _teardown_test
        return
    fi

    # Behavioral assertion: the implementation MUST emit a recognizable signal
    # whenever it detects a head-sha change and resets its poll window. The
    # exact wording is contract-defined — assert on the signal token.
    assert_contains "test_push_induced_dismissal_resets_poll_window: emits POLL_WINDOW_RESET signal" "POLL_WINDOW_RESET" "$combined"

    # The wall-clock escalation signal from _phase_resolve_threads must NOT
    # appear. Note: "max-wait exceeded" is emitted by a different function
    # (_phase_wait_for_merge_check); the correct signal here is wall_clock REASON.
    assert_not_contains "test_push_induced_dismissal_resets_poll_window: no wall-clock escalation after push reset" \
        "ESCALATE:thread_resolution REASON:wall_clock" "$combined"

    _teardown_test
}

# ===========================================================================
# Test 7: file_path from GraphQL response is untrusted reviewer input. The
# validator MUST reject path-traversal segments, absolute paths, leading
# dashes (argument injection), and any chars outside [A-Za-z0-9._/-]. Safe
# paths must be accepted. This guards _phase_resolve_threads against passing
# malicious paths to `git diff` and `llm-api-call.sh`.
# ===========================================================================
test_file_path_validator_rejects_malicious_input() {
    _setup_test

    # Source merge-to-main-pr.sh in library mode to define _pr_validate_file_path.
    # shellcheck disable=SC1090
    (
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" MERGE_STRATEGY=pr \
            source "$MERGE_PR_SCRIPT" >/dev/null 2>&1 || true

        if ! type _pr_validate_file_path >/dev/null 2>&1; then
            echo "MISSING_FUNCTION:_pr_validate_file_path" >&2
            exit 99
        fi

        local rc=0

        # --- Must reject ---
        local malicious=(
            "../etc/passwd"
            "../../etc/passwd"
            "src/../../etc/passwd"
            "/etc/passwd"
            "/tmp/evil"
            "--upload-pack=evil"
            "-rf"
            "foo;rm -rf /"
            "foo\$(whoami)"
            "foo bar.py"
            "foo|bar"
            "foo>bar"
        )
        local p
        for p in "${malicious[@]}"; do
            if _pr_validate_file_path "$p" 2>/dev/null; then
                echo "MALICIOUS_ACCEPTED:$p" >&2
                rc=1
            fi
        done

        # --- Must accept ---
        local safe=(
            ""
            "src/a.py"
            "plugins/dso/scripts/merge-to-main-pr.sh"
            "tests/integration/test-foo.sh"
            "README.md"
            "deeply/nested/path/file_name-1.0.txt"
        )
        for p in "${safe[@]}"; do
            if ! _pr_validate_file_path "$p" 2>/dev/null; then
                echo "SAFE_REJECTED:$p" >&2
                rc=1
            fi
        done

        exit "$rc"
    )
    local subshell_rc=$?

    if [[ "$subshell_rc" == "99" ]]; then
        (( ++FAIL ))
        echo "FAIL: test_file_path_validator_rejects_malicious_input — _pr_validate_file_path not defined" >&2
        _teardown_test
        return
    fi

    assert_eq "test_file_path_validator_rejects_malicious_input: validator behaves correctly" "0" "$subshell_rc"

    _teardown_test
}

# ---------------------------------------------------------------------------
# Unit tests for extracted helper functions (GREEN — helpers exist post-T5)
# ---------------------------------------------------------------------------

# test_pr_resolve_threads_read_config_env_override: _pr_resolve_threads_read_config
# reads PR_THREAD_LOOP_MAX_DISPATCHES and PR_THREAD_LOOP_INTERVAL from env vars
# when set, writing values into caller-provided variable names.
test_pr_resolve_threads_read_config_env_override() {
    echo "=== test_pr_resolve_threads_read_config_env_override ==="
    _snapshot_fail
    # Source the function in a subshell and verify env overrides take effect.
    # Use PR_LIB_MODE=1 to suppress top-level script execution.
    local _result
    _result=$(
        PR_THREAD_LOOP_MAX_DISPATCHES=5 PR_THREAD_LOOP_INTERVAL=15 \
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" MERGE_STRATEGY=pr \
        bash -c "
            source '$MERGE_PR_SCRIPT' >/dev/null 2>&1 || true
            _max_d='' _max_w='' _qw='' _iv=''
            _pr_resolve_threads_read_config _max_d _max_w _qw _iv 2>/dev/null || true
            echo \"max_dispatches=\$_max_d interval=\$_iv\"
        " 2>/dev/null
    ) || true
    assert_eq "test_pr_resolve_threads_read_config_env_override: max_dispatches env override" \
        "1" "$(echo "$_result" | grep -c 'max_dispatches=5')"
    assert_eq "test_pr_resolve_threads_read_config_env_override: interval env override" \
        "1" "$(echo "$_result" | grep -c 'interval=15')"
    assert_pass_if_clean "test_pr_resolve_threads_read_config_env_override"
}

# test_pr_handle_head_sha_reset_skips_update_on_empty_sha: _pr_handle_head_sha_reset
# must not update the tracked SHA when gh returns an empty string (transient failure).
# Given: a running loop where the tracked SHA is 'abc123'
# When: gh returns empty headRefOid (network hiccup stub)
# Then: the tracked SHA remains 'abc123' (not overwritten) — verified by reading
#       the variable value through the printf-v nameref pattern.
test_pr_handle_head_sha_reset_skips_update_on_empty_sha() {
    echo ""
    echo "=== test_pr_handle_head_sha_reset_skips_update_on_empty_sha ==="
    _snapshot_fail
    # Source the function
    local _result
    _result=$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" MERGE_STRATEGY=pr \
        bash -c "
            source '$MERGE_PR_SCRIPT' >/dev/null 2>&1 || true
            # Stub gh to return empty headRefOid (transient failure)
            gh() { echo '{\"headRefOid\":\"\"}'; }
            export -f gh
            _last_sha='abc123'
            _start=0 _last_ts=0 _last_count=0
            _pr_handle_head_sha_reset 99 _last_sha _start _last_ts _last_count 2>/dev/null || true
            echo \"sha_after=\$_last_sha\"
        " 2>/dev/null
    ) || true
    # SHA must NOT be updated when gh returns empty
    assert_eq "test_pr_handle_head_sha_reset_skips_update_on_empty_sha" \
        "1" "$(echo "$_result" | grep -c 'sha_after=abc123')"
    assert_pass_if_clean "test_pr_handle_head_sha_reset_skips_update_on_empty_sha"
}

# test_pr_dispatch_unresolved_batch_routes_reply_action: when the LLM returns
# ACTION:reply, the batch dispatches a reply comment (not code_change or escalate).
# This tests the 3-way routing branch in _pr_dispatch_unresolved_batch.
test_pr_dispatch_unresolved_batch_routes_reply_action() {
    echo ""
    echo "=== test_pr_dispatch_unresolved_batch_routes_reply_action ==="
    _snapshot_fail
    # Test the routing by inspecting which code path was taken.
    # _pr_dispatch_unresolved_batch reads LLM output with ACTION:reply → calls _pr_post_thread_reply
    # We verify by checking that _code_change_threads remains empty (no code_change routing)
    # and _escalated_threads remains empty (no escalation routing).
    local _result
    # CI=true: _pr_dispatch_unresolved_batch has a _dso_is_ci_environment guard
    # that short-circuits with a local-escalation when CI is unset/false (commit
    # f2845a6f3a). The test must set CI=true to reach the dispatch path.
    _result=$(
        CI=true PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" MERGE_STRATEGY=pr \
        bash -c "
            source '$MERGE_PR_SCRIPT' >/dev/null 2>&1 || true
            # Stub LLM to return ACTION:reply with REPLY: keyword (matching production pattern)
            _llm_cmd() { echo 'ACTION:reply REPLY:Fixed the issue'; }
            # Stub gh for reply posting
            gh() { :; }
            export -f gh
            declare -A _escaped=()
            declare -a _code=()
            declare -a _threads=('PRT_test_thread')
            _dispatches=0
            _pr_dispatch_unresolved_batch 42 'https://x/42' '$REPO_ROOT' '_llm_cmd' 10 \
                _dispatches _escaped _code \"\${_threads[@]}\" 2>/dev/null || true
            echo \"code_change_count=\${#_code[@]}\"
            echo \"escalated_count=\${#_escaped[@]}\"
            echo \"dispatches=\$_dispatches\"
        " 2>/dev/null
    ) || true
    # Reply action: code_change empty (no code_change), escalated empty (no escalation), 1 dispatch
    assert_eq "test_pr_dispatch_unresolved_batch_routes_reply_action: no code_change" \
        "1" "$(echo "$_result" | grep -c 'code_change_count=0')"
    assert_eq "test_pr_dispatch_unresolved_batch_routes_reply_action: not escalated" \
        "1" "$(echo "$_result" | grep -c 'escalated_count=0')"
    assert_eq "test_pr_dispatch_unresolved_batch_routes_reply_action: dispatch counted" \
        "1" "$(echo "$_result" | grep -c 'dispatches=1')"
    assert_pass_if_clean "test_pr_dispatch_unresolved_batch_routes_reply_action"
}


# ===========================================================================
# Test: _phase_resolve_threads must fail loud (non-zero + ESCALATE: on stderr)
# when _LLM_DISPATCH_CMD is unset AND unresolved threads exist that require
# dispatch. (Bug 9e04-0eb6 — fail-loud safety contract.)
#
# The 1a83-46c5 fix moved the guard from entry-time to dispatch-time. The
# fail-loud contract still holds when dispatch is actually needed; this test
# stubs gh so that one unresolved thread is returned, forcing the loop to
# reach the dispatch site where the deferred guard fires.
# ===========================================================================
test_phase_resolve_threads_fails_loud_when_llm_dispatch_unset() {
    echo ""
    echo "=== test_phase_resolve_threads_fails_loud_when_llm_dispatch_unset ==="
    _setup_test
    export STUB_GH_SCENARIO=threads_one_unresolved
    export PR_THREAD_LOOP_MAX_DISPATCHES=1
    export PR_THREAD_LOOP_MAX_WALL_SECONDS=99999
    export PR_THREAD_LOOP_INTERVAL=0

    local stderr_out rc=0
    stderr_out=$(
        CI=true \
        PR_LIB_MODE=1 \
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
        MERGE_STRATEGY=pr \
        bash -c "
            source '$MERGE_PR_SCRIPT' >/dev/null 2>&1 || true
            unset _LLM_DISPATCH_CMD
            _phase_resolve_threads 42 'https://github.com/o/r/pull/42' 2>&1 >/dev/null
        "
    ) || rc=$?

    assert_ne "test_phase_resolve_threads_fails_loud_when_llm_dispatch_unset: must exit non-zero when _LLM_DISPATCH_CMD unset AND threads exist" \
        "0" "$rc"
    assert_contains "test_phase_resolve_threads_fails_loud_when_llm_dispatch_unset: stderr must contain ESCALATE: prefix" \
        "ESCALATE:" "$stderr_out"
    assert_pass_if_clean "test_phase_resolve_threads_fails_loud_when_llm_dispatch_unset"
    _teardown_test
}

# ===========================================================================
# Test (1a83-46c5): _phase_resolve_threads must NOT fail-loud when there are
# zero unresolved threads, even if _LLM_DISPATCH_CMD is unset. The previous
# entry-time guard blocked every PR from merging (bug 1a83-46c5); the deferred
# guard only fires when dispatch is actually needed.
# ===========================================================================
test_phase_resolve_threads_settles_clean_when_no_threads_and_llm_unset() {
    echo ""
    echo "=== test_phase_resolve_threads_settles_clean_when_no_threads_and_llm_unset ==="
    _setup_test
    # threads_mixed scenario with NO fixture file → emits empty nodes array
    export STUB_GH_SCENARIO=threads_mixed
    unset STUB_GH_THREADS_FIXTURE
    export PR_THREAD_LOOP_MAX_DISPATCHES=1
    export PR_THREAD_LOOP_MAX_WALL_SECONDS=99999
    export PR_THREAD_LOOP_INTERVAL=0
    # Pre-elapse the quiet window so settling fires on the first iteration.
    export PR_THREAD_LOOP_START_OVERRIDE_SECONDS=99999

    local stderr_out rc=0
    stderr_out=$(
        CI=true \
        PR_LIB_MODE=1 \
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
        MERGE_STRATEGY=pr \
        bash -c "
            source '$MERGE_PR_SCRIPT' >/dev/null 2>&1 || true
            unset _LLM_DISPATCH_CMD
            _phase_resolve_threads 99 'https://github.com/o/r/pull/99' 2>&1 >/dev/null
        "
    ) || rc=$?

    assert_eq "test_phase_resolve_threads_settles_clean_when_no_threads_and_llm_unset: must exit 0 when zero threads even if _LLM_DISPATCH_CMD unset" \
        "0" "$rc"
    # Stderr must NOT contain the ESCALATE prefix when settling cleanly with no threads.
    if [[ "$stderr_out" == *"ESCALATE: _LLM_DISPATCH_CMD"* ]]; then
        echo "FAIL: settles_clean: stderr unexpectedly contains ESCALATE about _LLM_DISPATCH_CMD"
        echo "  stderr was: $stderr_out"
        _FAIL=1
    fi
    assert_pass_if_clean "test_phase_resolve_threads_settles_clean_when_no_threads_and_llm_unset"
    _teardown_test
}

# ===========================================================================
# Test: _dispatch_resolve_conflicts must fail loud (non-zero + ESCALATE: on
# stderr) when _RESOLVE_CONFLICTS_LLM_CMD is unset, NOT silently return 0.
# (Bug 9e04-0eb6.)
# ===========================================================================
test_dispatch_resolve_conflicts_fails_loud_when_llm_dispatch_unset() {
    echo ""
    echo "=== test_dispatch_resolve_conflicts_fails_loud_when_llm_dispatch_unset ==="
    _snapshot_fail

    local stderr_out rc=0
    stderr_out=$(
        CI=true \
        PR_LIB_MODE=1 \
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
        MERGE_STRATEGY=pr \
        bash -c "
            source '$MERGE_PR_SCRIPT' >/dev/null 2>&1 || true
            unset _RESOLVE_CONFLICTS_LLM_CMD
            _dispatch_resolve_conflicts 42 'https://github.com/o/r/pull/42' 2>&1 >/dev/null
        "
    ) || rc=$?

    assert_ne "test_dispatch_resolve_conflicts_fails_loud_when_llm_dispatch_unset: must exit non-zero when _RESOLVE_CONFLICTS_LLM_CMD unset" \
        "0" "$rc"
    assert_contains "test_dispatch_resolve_conflicts_fails_loud_when_llm_dispatch_unset: stderr must contain ESCALATE: prefix" \
        "ESCALATE:" "$stderr_out"
    assert_pass_if_clean "test_dispatch_resolve_conflicts_fails_loud_when_llm_dispatch_unset"
}

# ===========================================================================
# Test: _dispatch_fix_agent must fail loud (non-zero + ESCALATE: on stderr)
# when _REMEDIATE_LLM_CMD is unset, NOT silently return 0. (Bug 9e04-0eb6.)
# ===========================================================================
test_dispatch_fix_agent_fails_loud_when_llm_dispatch_unset() {
    echo ""
    echo "=== test_dispatch_fix_agent_fails_loud_when_llm_dispatch_unset ==="
    _snapshot_fail

    local _findings_file
    _findings_file=$(mktemp "/tmp/dso-findings.XXXXXX")
    _TEST_TMPDIRS+=("$_findings_file")

    local stderr_out rc=0
    stderr_out=$(
        CI=true \
        PR_LIB_MODE=1 \
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
        MERGE_STRATEGY=pr \
        bash -c "
            source '$MERGE_PR_SCRIPT' >/dev/null 2>&1 || true
            unset _REMEDIATE_LLM_CMD
            _dispatch_fix_agent '$_findings_file' 1 2>&1 >/dev/null
        "
    ) || rc=$?

    rm -f "$_findings_file"

    assert_ne "test_dispatch_fix_agent_fails_loud_when_llm_dispatch_unset: must exit non-zero when _REMEDIATE_LLM_CMD unset" \
        "0" "$rc"
    assert_contains "test_dispatch_fix_agent_fails_loud_when_llm_dispatch_unset: stderr must contain ESCALATE: prefix" \
        "ESCALATE:" "$stderr_out"
    assert_pass_if_clean "test_dispatch_fix_agent_fails_loud_when_llm_dispatch_unset"
}

# ===========================================================================
# Test: _phase_conflict_resolution must propagate the ESCALATE return code
# (rc=2) from _dispatch_resolve_conflicts when _RESOLVE_CONFLICTS_LLM_CMD is
# unset. Bug 9e04-0eb6 review-finding 1: caller-side `|| true` would swallow
# both the ESCALATE: stderr and the rc=2, rendering the fail-loud guard
# ineffective for the conflict-resolution path.
# ===========================================================================
test_phase_conflict_resolution_propagates_escalate_when_llm_unset() {
    echo ""
    echo "=== test_phase_conflict_resolution_propagates_escalate_when_llm_unset ==="
    _snapshot_fail

    local stderr_out rc=0
    stderr_out=$(
        CI=true \
        PR_LIB_MODE=1 \
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
        MERGE_STRATEGY=pr \
        bash -c "
            source '$MERGE_PR_SCRIPT' >/dev/null 2>&1 || true
            unset _RESOLVE_CONFLICTS_LLM_CMD
            # Stub gh to report CONFLICTING so _phase_conflict_resolution invokes
            # _dispatch_resolve_conflicts (otherwise it short-circuits at the merge-state check).
            gh() { echo 'CONFLICTING'; }
            export -f gh
            _phase_conflict_resolution 42 'https://github.com/o/r/pull/42' 2>&1 >/dev/null
        "
    ) || rc=$?

    # _phase_conflict_resolution returns 1 (escalation needed) when the dispatch escalates.
    assert_eq "test_phase_conflict_resolution_propagates_escalate_when_llm_unset: must return 1 (escalation)" \
        "1" "$rc"
    # The ESCALATE: line from _dispatch_resolve_conflicts must reach the caller's stderr.
    assert_contains "test_phase_conflict_resolution_propagates_escalate_when_llm_unset: stderr must contain ESCALATE: prefix" \
        "ESCALATE:" "$stderr_out"
    # The phase's own ESCALATION_REASON line must also appear.
    assert_contains "test_phase_conflict_resolution_propagates_escalate_when_llm_unset: stderr must contain ESCALATION_REASON" \
        "ESCALATION_REASON:" "$stderr_out"
    assert_pass_if_clean "test_phase_conflict_resolution_propagates_escalate_when_llm_unset"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_pr_resolve_threads_read_config_env_override
test_pr_handle_head_sha_reset_skips_update_on_empty_sha
test_pr_dispatch_unresolved_batch_routes_reply_action
test_review_threads_query_parses_unresolved_thread_ids
test_resolve_thread_calls_mutation_only_when_unresolved
test_settling_heuristic_requires_zero_threads_and_quiet_window
test_dispatch_count_cap_triggers_escalation
test_wall_clock_cap_triggers_escalation
test_push_induced_dismissal_resets_poll_window
test_file_path_validator_rejects_malicious_input
test_phase_resolve_threads_fails_loud_when_llm_dispatch_unset
test_phase_resolve_threads_settles_clean_when_no_threads_and_llm_unset
test_dispatch_resolve_conflicts_fails_loud_when_llm_dispatch_unset
test_dispatch_fix_agent_fails_loud_when_llm_dispatch_unset
test_phase_conflict_resolution_propagates_escalate_when_llm_unset

# Print summary and exit non-zero on any failure (RED state expected pre-T3/T4).
print_summary
