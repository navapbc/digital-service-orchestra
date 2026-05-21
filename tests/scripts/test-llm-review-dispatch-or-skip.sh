#!/usr/bin/env bash
# shellcheck disable=SC2016
# tests/scripts/test-llm-review-dispatch-or-skip.sh
# RED-phase behavioral tests for plugins/dso/scripts/llm-review-dispatch-or-skip.sh
#
# Verifies that the wrapper script routes correctly based on
# verify-session-provenance.sh exit codes:
#   exit 0 → skip LLM dispatch; emit 'skipped' check-run conclusion with
#            sub-PR liveness summary listing covering sub-PRs
#   exit 1 → invoke ci-llm-review-runner.sh (full-diff path)
#   exit 2 → invoke ci-llm-review-runner.sh (full-diff path)
#   exit 3 → skip dispatch; emit 'skipped' conclusion +
#            'OVER_BOUND: acknowledged non-provenanced; routed to admin/FP-recovery'
#
# All tests FAIL until plugins/dso/scripts/llm-review-dispatch-or-skip.sh
# is created (RED gate confirmed — S3.T2 implements the script).
#
# Usage: bash tests/scripts/test-llm-review-dispatch-or-skip.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED marker: [test_llm_review_dispatch_or_skip]
# Target:     plugins/dso/scripts/llm-review-dispatch-or-skip.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_ROOT/plugins/dso/scripts/llm-review-dispatch-or-skip.sh"
VERIFIER="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"
RUNNER="$REPO_ROOT/plugins/dso/scripts/ci-llm-review-runner.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-llm-review-dispatch-or-skip.sh ==="

# ── Setup ─────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# ── Helper: create a mock verifier that exits with a given code ───────────────
_make_mock_verifier() {
    local exit_code="$1"
    local pr_list="${2:-}"  # optional JSON array of sub-PR numbers for exit 0
    cat > "$MOCK_BIN/verify-session-provenance.sh" << MOCKEOF
#!/usr/bin/env bash
# Mock verify-session-provenance.sh — exits $exit_code
# shellcheck disable=SC2016
${pr_list:+echo '$pr_list'}
exit $exit_code
MOCKEOF
    chmod +x "$MOCK_BIN/verify-session-provenance.sh"
}

# ── Helper (bug 8a77 v2): pre-populate artifact-driven dispatcher inputs ─────
# After Change B, the dispatcher reads artifacts (provenance-complete.marker,
# unprovenanced-shas.txt, over-bound-shas.txt, covered-shas.txt) instead of
# re-invoking the verifier. This helper sets up the artifact dir to simulate
# each verifier outcome.
#
# Usage: _seed_artifacts <dir> <outcome> [<sha-list>]
#   outcome: all_provenanced | unprovenanced | overbound | no_marker
#   sha-list: optional newline-separated SHAs to seed into the relevant file
_seed_artifacts() {
    local dir="$1" outcome="$2" shalist="${3:-}"
    case "$outcome" in
        all_provenanced)
            date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/provenance-complete.marker"
            if [[ -n "$shalist" ]]; then
                printf '%s\n' "$shalist" > "$dir/covered-shas.txt"
            else
                : > "$dir/covered-shas.txt"
            fi
            ;;
        unprovenanced)
            date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/provenance-complete.marker"
            printf '%s\n' "${shalist:-deadbeef}" > "$dir/unprovenanced-shas.txt"
            ;;
        overbound)
            date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/provenance-complete.marker"
            printf '%s\n' "${shalist:-cafef00d}" > "$dir/over-bound-shas.txt"
            ;;
        no_marker)
            : # leave artifact dir empty
            ;;
    esac
}

# ── Helper: create a mock runner that records invocation ─────────────────────
_make_mock_runner() {
    local call_log="$1"
    cat > "$MOCK_BIN/ci-llm-review-runner.sh" << MOCKEOF
#!/usr/bin/env bash
# Mock ci-llm-review-runner.sh — records invocation
echo "runner-called" >> "$call_log"
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/ci-llm-review-runner.sh"
}

# ── Test 1: wrapper script exists and is executable ───────────────────────────
test_wrapper_exists() {
    _snapshot_fail
    local exists
    if [[ -f "$WRAPPER" && -x "$WRAPPER" ]]; then exists="yes"; else exists="no"; fi
    assert_eq "test_wrapper_exists: llm-review-dispatch-or-skip.sh exists and is executable" \
        "yes" "$exists"
    assert_pass_if_clean "test_wrapper_exists"
}

# ── Test 2: exit 0 → wrapper skips dispatch (runner NOT called) ──────────────
# When verify-session-provenance.sh exits 0, all commits are provenanced.
# The wrapper must NOT call ci-llm-review-runner.sh.
test_exit0_skips_runner() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_exit0_skips_runner: wrapper must exist to test routing" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_exit0_skips_runner"
        return
    fi

    _make_mock_verifier 0
    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-calls.XXXXXX")"
    _make_mock_runner "$call_log"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "all_provenanced"

    DSO_VERIFIER_PATH="$MOCK_BIN/verify-session-provenance.sh" \
    DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" 2>/dev/null || true

    local runner_called="no"
    if [[ -f "$call_log" ]] && grep -q "runner-called" "$call_log" 2>/dev/null; then
        runner_called="yes"
    fi
    assert_eq "test_exit0_skips_runner: runner NOT called when verifier exits 0" \
        "no" "$runner_called"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_exit0_skips_runner"
}

# ── Test 3: exit 0 → wrapper emits 'skipped' check-run conclusion ────────────
# The wrapper must emit a conclusion of 'skipped' (not 'failure' or 'success')
# when all commits are provenanced.
test_exit0_emits_skipped_conclusion() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_exit0_emits_skipped_conclusion: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_exit0_emits_skipped_conclusion"
        return
    fi

    _make_mock_verifier 0
    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "all_provenanced"

    local output
    output=$(
        DSO_VERIFIER_PATH="$MOCK_BIN/verify-session-provenance.sh" \
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || true

    assert_contains "test_exit0_emits_skipped_conclusion: output contains 'skipped' conclusion" \
        "skipped" "$output"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_exit0_emits_skipped_conclusion"
}

# ── Test 4: exit 0 → summary lists covering sub-PR liveness assertion ─────────
# When skipping, the wrapper must emit a liveness assertion referencing the
# sub-PRs that cover the provenanced commits (coverage is non-empty reference).
test_exit0_liveness_assertion_in_summary() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_exit0_liveness_assertion_in_summary: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_exit0_liveness_assertion_in_summary"
        return
    fi

    _make_mock_verifier 0
    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "all_provenanced"

    local output
    output=$(
        DSO_VERIFIER_PATH="$MOCK_BIN/verify-session-provenance.sh" \
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || true

    # The summary must contain some reference to sub-PR coverage
    # (either "sub-PR", "covered-by", or a PR number pattern)
    local has_coverage
    if echo "$output" | grep -qiE "sub-pr|covered.by|covering|provenance|sub_pr|#[0-9]+"; then
        has_coverage="yes"
    else
        has_coverage="no"
    fi
    assert_eq "test_exit0_liveness_assertion_in_summary: summary references sub-PR coverage" \
        "yes" "$has_coverage"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_exit0_liveness_assertion_in_summary"
}

# ── Test 5: exit 1 → wrapper invokes runner (unprovenanced path) ─────────────
# When verify-session-provenance.sh exits 1, one or more commits lack
# provenance. The wrapper MUST call ci-llm-review-runner.sh.
test_exit1_invokes_runner() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_exit1_invokes_runner: wrapper must exist to test routing" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_exit1_invokes_runner"
        return
    fi

    _make_mock_verifier 1
    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-calls-exit1.XXXXXX")"
    _make_mock_runner "$call_log"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "unprovenanced"

    DSO_VERIFIER_PATH="$MOCK_BIN/verify-session-provenance.sh" \
    DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" 2>/dev/null || true

    local runner_called="no"
    if [[ -f "$call_log" ]] && grep -q "runner-called" "$call_log" 2>/dev/null; then
        runner_called="yes"
    fi
    assert_eq "test_exit1_invokes_runner: runner IS called when verifier exits 1 (unprovenanced)" \
        "yes" "$runner_called"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_exit1_invokes_runner"
}

# ── Test 6: budget-exhausted state routes to runner ───────────────────────────
# Pre-bug-8a77-v2: wrapper invoked verifier; this case covered verifier exit 2.
# Post-v2: wrapper reads artifacts and treats a non-empty unprovenanced-shas.txt
# (which the verifier writes for partial / budget-exhausted runs per verifier
# lines 297, 317, 335) as the dispatch trigger — same end behavior, different
# data flow. ci-llm-review-runner.sh must be called.
test_exit2_invokes_runner() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_exit2_invokes_runner: wrapper must exist to test routing" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_exit2_invokes_runner"
        return
    fi

    _make_mock_verifier 2
    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-calls-exit2.XXXXXX")"
    _make_mock_runner "$call_log"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    # Budget-exhausted: verifier still writes unprovenanced-shas.txt for the
    # incompletely-checked commits (verifier source lines 297-298, 317, 335).
    # The dispatcher's artifact route consumes that as exit 1 → invoke runner.
    _seed_artifacts "$artifact_dir" "unprovenanced"

    DSO_VERIFIER_PATH="$MOCK_BIN/verify-session-provenance.sh" \
    DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" 2>/dev/null || true

    local runner_called="no"
    if [[ -f "$call_log" ]] && grep -q "runner-called" "$call_log" 2>/dev/null; then
        runner_called="yes"
    fi
    assert_eq "test_exit2_invokes_runner: runner IS called when verifier exits 2 (budget-exhausted)" \
        "yes" "$runner_called"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_exit2_invokes_runner"
}

# ── Test 7: exit 3 → wrapper skips dispatch (OVER_BOUND path) ────────────────
# When verify-session-provenance.sh exits 3 (OVER_BOUND — non-provenanced
# commits acknowledged and routed to admin/FP-recovery), the wrapper must NOT
# call ci-llm-review-runner.sh.
test_exit3_skips_runner() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_exit3_skips_runner: wrapper must exist to test routing" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_exit3_skips_runner"
        return
    fi

    _make_mock_verifier 3
    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-calls-exit3.XXXXXX")"
    _make_mock_runner "$call_log"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "overbound"

    DSO_VERIFIER_PATH="$MOCK_BIN/verify-session-provenance.sh" \
    DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" 2>/dev/null || true

    local runner_called="no"
    if [[ -f "$call_log" ]] && grep -q "runner-called" "$call_log" 2>/dev/null; then
        runner_called="yes"
    fi
    assert_eq "test_exit3_skips_runner: runner NOT called when verifier exits 3 (OVER_BOUND)" \
        "no" "$runner_called"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_exit3_skips_runner"
}

# ── Test 8: exit 3 → wrapper emits 'skipped' conclusion + OVER_BOUND message ─
# For exit code 3, the wrapper must:
#   (a) emit a 'skipped' check-run conclusion
#   (b) include 'OVER_BOUND' in the summary
#   (c) mention 'admin/FP-recovery' routing
test_exit3_emits_over_bound_summary() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_exit3_emits_over_bound_summary: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_exit3_emits_over_bound_summary"
        return
    fi

    _make_mock_verifier 3
    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "overbound"

    local output
    output=$(
        DSO_VERIFIER_PATH="$MOCK_BIN/verify-session-provenance.sh" \
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || true

    assert_contains "test_exit3_emits_over_bound_summary: output contains 'skipped'" \
        "skipped" "$output"

    assert_contains "test_exit3_emits_over_bound_summary: output contains 'OVER_BOUND'" \
        "OVER_BOUND" "$output"

    # Check for FP-recovery / admin routing reference
    local has_routing
    if echo "$output" | grep -qiE "admin|fp-recovery|FP_recovery"; then
        has_routing="yes"
    else
        has_routing="no"
    fi
    assert_eq "test_exit3_emits_over_bound_summary: output references admin/FP-recovery routing" \
        "yes" "$has_routing"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_exit3_emits_over_bound_summary"
}

# ── Test 9 (bug 8a77 v2): no marker → exits 1 with diagnostic ─────────────────
# When the verifier never wrote provenance-complete.marker (crash, never ran,
# permission failure, etc.), the dispatcher MUST exit 1 with a descriptive
# error rather than silently falling through to "all provenanced" exit 0.
test_dispatcher_no_marker_exits_1() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_no_marker_exits_1: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_no_marker_exits_1"
        return
    fi

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "no_marker"

    local stderr_file
    stderr_file="$(mktemp)"
    local exit_code=99
    DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" > /dev/null 2> "$stderr_file"
    exit_code=$?

    assert_eq "test_dispatcher_no_marker_exits_1: missing marker exits 1" \
        "1" "$exit_code"

    local stderr_content
    stderr_content=$(cat "$stderr_file")
    assert_contains "test_dispatcher_no_marker_exits_1: stderr names the marker" \
        "provenance-complete.marker" "$stderr_content"

    rm -rf "$artifact_dir" "$stderr_file"
    assert_pass_if_clean "test_dispatcher_no_marker_exits_1"
}

# ── Test 10 (bug 8a77 v2): marker only (no unprov/overbound) → skipped ────────
test_dispatcher_marker_only_skipped() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_marker_only_skipped: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_marker_only_skipped"
        return
    fi

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "all_provenanced"

    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-calls-marker-only.XXXXXX")"
    _make_mock_runner "$call_log"

    local output
    output=$(
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || true

    assert_contains "test_dispatcher_marker_only_skipped: output contains 'CONCLUSION: skipped'" \
        "CONCLUSION: skipped" "$output"

    local runner_called="no"
    if [[ -f "$call_log" ]] && grep -q "runner-called" "$call_log" 2>/dev/null; then
        runner_called="yes"
    fi
    assert_eq "test_dispatcher_marker_only_skipped: runner NOT invoked" \
        "no" "$runner_called"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_dispatcher_marker_only_skipped"
}

# ── Test 11 (bug 8a77 v2 MF1): overbound artifact routes correctly ────────────
test_dispatcher_overbound_routes_correctly() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_overbound_routes_correctly: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_overbound_routes_correctly"
        return
    fi

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "overbound" "feedf00d"

    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-calls-overbound.XXXXXX")"
    _make_mock_runner "$call_log"

    local output
    output=$(
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || true

    assert_contains "test_dispatcher_overbound_routes_correctly: output contains 'CONCLUSION: skipped'" \
        "CONCLUSION: skipped" "$output"
    assert_contains "test_dispatcher_overbound_routes_correctly: output contains 'OVER_BOUND'" \
        "OVER_BOUND" "$output"

    local runner_called="no"
    if [[ -f "$call_log" ]] && grep -q "runner-called" "$call_log" 2>/dev/null; then
        runner_called="yes"
    fi
    assert_eq "test_dispatcher_overbound_routes_correctly: runner NOT invoked on overbound" \
        "no" "$runner_called"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_dispatcher_overbound_routes_correctly"
}

# ── Test 12 (bug 8a77 v2): unprovenanced artifact → runner dispatched ─────────
test_dispatcher_unprovenanced_dispatches_runner() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_unprovenanced_dispatches_runner: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_unprovenanced_dispatches_runner"
        return
    fi

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "unprovenanced" "deadbeef"

    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-calls-unprov.XXXXXX")"
    cat > "$MOCK_BIN/ci-llm-review-runner.sh" << MOCKEOF
#!/usr/bin/env bash
echo "MOCK_INVOKED" >> "$call_log"
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/ci-llm-review-runner.sh"

    DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" > /dev/null 2>/dev/null || true

    local mock_invoked="no"
    if [[ -f "$call_log" ]] && grep -q "MOCK_INVOKED" "$call_log" 2>/dev/null; then
        mock_invoked="yes"
    fi
    assert_eq "test_dispatcher_unprovenanced_dispatches_runner: mock runner invoked" \
        "yes" "$mock_invoked"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_dispatcher_unprovenanced_dispatches_runner"
}

# ── Test 13 (bug 8a77 v2): covered list from artifact appears in output ───────
# The "Covered by sub-PR reviews:" line MUST render its identifier list from
# the covered-shas.txt artifact rather than re-walking BASE..HEAD (the
# shallow-clone vulnerability).
test_dispatcher_covered_list_from_artifact() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_covered_list_from_artifact: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_covered_list_from_artifact"
        return
    fi

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    # Seed covered-shas.txt with two recognizable SHAs
    _seed_artifacts "$artifact_dir" "all_provenanced" "$(printf 'aaaaaaaa11111111\nbbbbbbbb22222222')"

    local output
    output=$(
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || true

    assert_contains "test_dispatcher_covered_list_from_artifact: output contains Covered by sub-PR reviews line" \
        "Covered by sub-PR reviews:" "$output"
    # Short forms of seeded SHAs (first 8 chars) should appear
    assert_contains "test_dispatcher_covered_list_from_artifact: output contains aaaaaaaa short SHA" \
        "aaaaaaaa" "$output"
    assert_contains "test_dispatcher_covered_list_from_artifact: output contains bbbbbbbb short SHA" \
        "bbbbbbbb" "$output"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_dispatcher_covered_list_from_artifact"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_wrapper_exists
test_exit0_skips_runner
test_exit0_emits_skipped_conclusion
test_exit0_liveness_assertion_in_summary
test_exit1_invokes_runner
test_exit2_invokes_runner
test_exit3_skips_runner
test_exit3_emits_over_bound_summary
test_dispatcher_no_marker_exits_1
test_dispatcher_marker_only_skipped
test_dispatcher_overbound_routes_correctly
test_dispatcher_unprovenanced_dispatches_runner
test_dispatcher_covered_list_from_artifact

print_summary
