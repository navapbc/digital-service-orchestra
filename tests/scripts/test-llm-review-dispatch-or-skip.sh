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

# CI environment isolation: the dispatcher reads $GITHUB_BASE_REF to derive
# its filter base (origin/$GITHUB_BASE_REF). On a pull_request CI event,
# GitHub Actions sets this to the PR's base branch — which under the
# two-tier promotion model can be a staged-<sha>-<ts> branch that doesn't
# exist in the test fixture's tmp repo. Test fixtures construct their own
# `origin/main` ref; clearing GITHUB_BASE_REF here forces the dispatcher
# to fall back to that default. Without this, every fixture would need to
# create a staged-<sha>-<ts> ref matching the live PR's base — brittle.
unset GITHUB_BASE_REF

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

# In CI (GITHUB_ACTIONS=true), real gh + GITHUB_REPOSITORY are set, which
# would trigger the dispatcher's _FORCE_REVIEW branch-pattern matching on
# every test running in a sub-agent-named worktree (e.g. worktree-*, feat-*).
# Force GITHUB_HEAD_REF=main so the dispatcher's _HEAD_BRANCH detection
# resolves to a non-force-review-eligible name. Tests that explicitly want
# to exercise force-review override this in their own scope.
export GITHUB_HEAD_REF="${DSO_TEST_HEAD_REF:-main}"

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
#
# v4 note: when `unprovenanced` or `overbound` outcome is requested without
# explicit SHA list, defaults to a REAL SHA from the test repo's history.
# This is required because R3a fails closed when commit-scoped `git show`
# produces an empty diff — fake SHAs like "deadbeef" previously worked
# because the dispatcher fell back to full PR diff. v4 removes that
# fallback to prevent the giant-diff failure mode, so SHAs must resolve.
#
# v4.1 update (PR-2 era): the SHA must ALSO be unreachable from origin/main,
# otherwise R3a's already-merged filter removes it from scope (correct
# behavior) and the dispatcher skips with "all_scope_already_merged" instead
# of invoking the runner. We use `git commit-tree` to create an ephemeral
# commit object that's not on any ref — git can resolve it (so `git show`
# works) but it's not in any rev-list output (so the filter keeps it).
_seed_artifacts() {
    local dir="$1" outcome="$2" shalist="${3:-}"
    # Create an ephemeral commit unreachable from any ref AND with a SMALL
    # non-empty tree diff against HEAD. Strategy: take HEAD's tree entries
    # via `git ls-tree HEAD`, append one new blob entry, then mktree the
    # combined list. This produces a tree identical to HEAD's plus one new
    # file → `git show` emits a 1-line addition diff. Guarantees:
    #   1. SHA is NOT on origin/main (no ref points to it)
    #   2. `git show <SHA>` produces a small non-empty diff (just the new file)
    #   3. Diff fits within R7d's size cap (5MB / 100 files) — far from cap
    # If any step fails, fall back to "deadbeef" — tests for that SHA exercise
    # the fail-closed path correctly.
    local real_sha
    local _ephemeral_blob _ephemeral_tree _ephemeral_name
    _ephemeral_name="test-ephemeral-$$-${RANDOM}.txt"
    _ephemeral_blob=$(echo "test-ephemeral-content-$$-$RANDOM" | git hash-object -w --stdin 2>/dev/null || echo "")
    if [[ -n "$_ephemeral_blob" ]]; then
        _ephemeral_tree=$(
            { git ls-tree HEAD 2>/dev/null;
              printf '100644 blob %s\t%s\n' "$_ephemeral_blob" "$_ephemeral_name";
            } | git mktree 2>/dev/null || echo ""
        )
        if [[ -n "$_ephemeral_tree" ]]; then
            real_sha=$(git commit-tree "$_ephemeral_tree" -p HEAD -m "test-ephemeral-$$-$RANDOM" 2>/dev/null || echo "deadbeef")
        else
            real_sha="deadbeef"
        fi
    else
        real_sha="deadbeef"
    fi
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
            printf '%s\n' "${shalist:-$real_sha}" > "$dir/unprovenanced-shas.txt"
            ;;
        overbound)
            date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/provenance-complete.marker"
            printf '%s\n' "${shalist:-$real_sha}" > "$dir/over-bound-shas.txt"
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

# ── Helper (bug 9788): create a mock `gh` that returns a small synthetic diff
# for `gh pr diff <N>`. Tests exercising the case 1|2 (dispatch-runner) branch
# need this because the dispatcher fetches the PR diff via `gh pr diff` to
# supply DSO_CI_REVIEW_DIFF_PATH to the runner.
_make_mock_gh() {
    cat > "$MOCK_BIN/gh" << 'MOCKGHEOF'
#!/usr/bin/env bash
# Mock gh — emits a 3-line synthetic diff for `gh pr diff <N>`, exits 0.
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
    cat << 'DIFFEOF'
diff --git a/x.py b/x.py
+pass
DIFFEOF
    exit 0
fi
echo "MOCK gh: unhandled args: $*" >&2
exit 1
MOCKGHEOF
    chmod +x "$MOCK_BIN/gh"
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
    # Bug 9788: dispatcher now requires PR_NUMBER + `gh pr diff` for case 1|2.
    _make_mock_gh

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "unprovenanced"

    PATH="$MOCK_BIN:$PATH" \
    PR_NUMBER=99 \
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
    # Bug 9788: dispatcher now requires PR_NUMBER + `gh pr diff` for case 1|2.
    _make_mock_gh

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    # Budget-exhausted: verifier still writes unprovenanced-shas.txt for the
    # incompletely-checked commits (verifier source lines 297-298, 317, 335).
    # The dispatcher's artifact route consumes that as exit 1 → invoke runner.
    _seed_artifacts "$artifact_dir" "unprovenanced"

    PATH="$MOCK_BIN:$PATH" \
    PR_NUMBER=99 \
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

# ── Test 7: exit 3 → wrapper blocks CI (OVER_BOUND path, G2 fix) ────────────
# When verify-session-provenance.sh exits 3 (OVER_BOUND — non-provenanced
# commits exceed review bounds), the wrapper must NOT call ci-llm-review-runner.sh
# AND must exit non-zero to block CI (G2 fix).
test_exit3_blocks_ci() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_exit3_blocks_ci: wrapper must exist to test routing" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_exit3_blocks_ci"
        return
    fi

    _make_mock_verifier 3
    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-calls-exit3.XXXXXX")"
    _make_mock_runner "$call_log"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "overbound"

    local exit_code=0
    DSO_VERIFIER_PATH="$MOCK_BIN/verify-session-provenance.sh" \
    DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" 2>/dev/null
    exit_code=$?

    local runner_called="no"
    if [[ -f "$call_log" ]] && grep -q "runner-called" "$call_log" 2>/dev/null; then
        runner_called="yes"
    fi
    assert_eq "test_exit3_blocks_ci: runner NOT called when verifier exits 3 (OVER_BOUND)" \
        "no" "$runner_called"

    assert_eq "test_exit3_blocks_ci: OVER_BOUND exits non-zero (G2 — blocks CI)" \
        "1" "$exit_code"

    rm -rf "$artifact_dir"
    assert_pass_if_clean "test_exit3_blocks_ci"
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

    assert_contains "test_exit3_emits_over_bound_summary: output contains 'blocked'" \
        "blocked" "$output"

    assert_contains "test_exit3_emits_over_bound_summary: output contains 'OVER_BOUND'" \
        "OVER_BOUND" "$output"

    # Check for FP-recovery routing reference (G2: now a hard block)
    local has_routing
    if echo "$output" | grep -qiE "fp-recovery|FP_recovery"; then
        has_routing="yes"
    else
        has_routing="no"
    fi
    assert_eq "test_exit3_emits_over_bound_summary: output references FP-recovery routing" \
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

    assert_contains "test_dispatcher_overbound_routes_correctly: output contains 'CONCLUSION: blocked'" \
        "CONCLUSION: blocked" "$output"
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
    _seed_artifacts "$artifact_dir" "unprovenanced"

    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-calls-unprov.XXXXXX")"
    cat > "$MOCK_BIN/ci-llm-review-runner.sh" << MOCKEOF
#!/usr/bin/env bash
echo "MOCK_INVOKED" >> "$call_log"
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/ci-llm-review-runner.sh"
    # Bug 9788: dispatcher now requires PR_NUMBER + `gh pr diff` for case 1|2.
    _make_mock_gh

    PATH="$MOCK_BIN:$PATH" \
    PR_NUMBER=99 \
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

# ── Test 14 (bug 9788): dispatcher supplies diff to runner via env var ────────
# Regression guard for bug 9788: when case 1|2 fires (unprovenanced-shas.txt
# non-empty), the dispatcher MUST supply the PR diff to ci-llm-review-runner.sh.
# Pre-S3.T3 ci.yml piped `gh pr diff "$PR_NUMBER"` into the runner; S3.T3
# replaced that with the dispatcher wrapper but dropped the diff input. Without
# a diff, runner.py:_read_diff() returns empty and the runner short-circuits
# before reaching the cycle-marker post call, making DISPATCH_ARBITER
# unreachable on live PRs (PRs #252–#262 had zero markers; PRs #245–#251 had
# markers as expected).
#
# Contract: dispatcher MUST either pipe the diff on stdin OR set
# DSO_CI_REVIEW_DIFF_PATH to a non-empty file before invoking the runner.
# This test exercises the env-var variant since it is the chosen fix (it
# preserves the runner's existing precedence: env-var wins over stdin).
test_dispatcher_supplies_diff_to_runner() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_supplies_diff_to_runner: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_supplies_diff_to_runner"
        return
    fi

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    _seed_artifacts "$artifact_dir" "unprovenanced"

    # Mock runner: capture DSO_CI_REVIEW_DIFF_PATH env var + (if set) its
    # content into a log file the test can inspect after dispatch.
    local env_log
    env_log="$(mktemp "$TMPDIR_TEST/runner-env-log.XXXXXX")"
    cat > "$MOCK_BIN/ci-llm-review-runner.sh" << MOCKEOF
#!/usr/bin/env bash
# Mock ci-llm-review-runner.sh — records DSO_CI_REVIEW_DIFF_PATH and content.
printf 'DSO_CI_REVIEW_DIFF_PATH=%s\n' "\${DSO_CI_REVIEW_DIFF_PATH:-UNSET}" >> "$env_log"
if [[ -n "\${DSO_CI_REVIEW_DIFF_PATH:-}" && -f "\${DSO_CI_REVIEW_DIFF_PATH}" ]]; then
    printf 'DIFF_BYTES=%s\n' "\$(wc -c < "\${DSO_CI_REVIEW_DIFF_PATH}" | tr -d ' ')" >> "$env_log"
else
    printf 'DIFF_BYTES=0\n' >> "$env_log"
fi
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/ci-llm-review-runner.sh"

    # Mock `gh` so the dispatcher's `gh pr diff "$PR_NUMBER"` call returns a
    # small synthetic diff without hitting the network.
    cat > "$MOCK_BIN/gh" << 'MOCKGHEOF'
#!/usr/bin/env bash
# Mock gh — emits a 3-line synthetic diff for `gh pr diff <N>`, exits 0.
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
    cat << 'DIFFEOF'
diff --git a/x.py b/x.py
+pass
DIFFEOF
    exit 0
fi
echo "MOCK gh: unhandled args: $*" >&2
exit 1
MOCKGHEOF
    chmod +x "$MOCK_BIN/gh"

    PATH="$MOCK_BIN:$PATH" \
    PR_NUMBER=99 \
    DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" > /dev/null 2>/dev/null || true

    # Assertion A: DSO_CI_REVIEW_DIFF_PATH was set (not UNSET) when runner ran.
    local env_log_content
    env_log_content="$(cat "$env_log" 2>/dev/null || true)"
    local diff_path_set="no"
    if echo "$env_log_content" | grep -qE '^DSO_CI_REVIEW_DIFF_PATH=/'; then
        diff_path_set="yes"
    fi
    assert_eq "test_dispatcher_supplies_diff_to_runner: DSO_CI_REVIEW_DIFF_PATH set to a file path" \
        "yes" "$diff_path_set"

    # Assertion B: the file pointed to was non-empty.
    local diff_nonempty="no"
    local bytes
    bytes="$(echo "$env_log_content" | grep -oE '^DIFF_BYTES=[0-9]+' | tail -1 | cut -d= -f2)"
    if [[ -n "$bytes" && "$bytes" != "0" ]]; then
        diff_nonempty="yes"
    fi
    assert_eq "test_dispatcher_supplies_diff_to_runner: diff file is non-empty" \
        "yes" "$diff_nonempty"

    rm -rf "$artifact_dir" "$env_log"
    assert_pass_if_clean "test_dispatcher_supplies_diff_to_runner"
}

# ── Tests 15 + 16 (G1 scope narrowing) deleted in v4 ─────────────────────────
# The G1 file-filter fallback path is unreachable in v4: when provenance_exit=1
# the dispatcher always has a populated _DISPATCH_SCOPE_FILE (either UNPROVENANCED_FILE
# or a force-scope file). The commit-scoped diff is narrowed by commit selection,
# not by file filter on the full PR diff. Coverage now provided by
# test_dispatcher_commit_scoped_diff and test_dispatcher_commit_scoped_diff_empty_fails_closed.

# ── Test 17 (F3): commit-scoped diff for unprovenanced SHAs ──────────────────
# When unprovenanced-shas.txt contains real SHAs, the dispatcher must generate
# a commit-scoped diff (via git show) instead of fetching the full PR diff.
# Only the unprovenanced commit's changes should appear in the diff.
test_dispatcher_commit_scoped_diff() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_commit_scoped_diff: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_commit_scoped_diff"
        return
    fi

    # Create a real git repo with two commits: one provenanced, one not
    local repo
    repo="$(mktemp -d)"
    git -C "$repo" init -b main > /dev/null 2>&1
    git -C "$repo" config user.name "Test" > /dev/null 2>&1
    git -C "$repo" config user.email "test@test.com" > /dev/null 2>&1

    printf 'line1\n' > "$repo/reviewed.py"
    git -C "$repo" add reviewed.py > /dev/null 2>&1
    git -C "$repo" commit -m "Reviewed commit" > /dev/null 2>&1

    # Set up origin/main BEFORE creating the unreviewed commit so the filter
    # can resolve origin/main but the unreviewed SHA is NOT yet on it (R3a v4.1).
    git -C "$repo" init --bare "$repo/origin.git" > /dev/null 2>&1
    git -C "$repo" remote add origin "$repo/origin.git" > /dev/null 2>&1
    git -C "$repo" push origin main > /dev/null 2>&1

    printf 'unreviewed change\n' > "$repo/unreviewed.py"
    git -C "$repo" add unreviewed.py > /dev/null 2>&1
    git -C "$repo" commit -m "Unreviewed commit" > /dev/null 2>&1
    local unprov_sha
    unprov_sha="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    # Seed with the real unprovenanced SHA
    date -u +%Y-%m-%dT%H:%M:%SZ > "$artifact_dir/provenance-complete.marker"
    printf '%s\n' "$unprov_sha" > "$artifact_dir/unprovenanced-shas.txt"

    # Mock gh: should NOT be called for diff (commit-scoped path skips gh pr diff)
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/gh" << 'MOCKGHEOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
    echo "ERROR: gh pr diff should not be called in commit-scoped path" >&2
    printf 'diff --git a/should_not_appear.py b/should_not_appear.py\n+FAIL\n'
    exit 0
fi
echo "MOCK gh: unhandled args: $*" >&2
exit 1
MOCKGHEOF
    chmod +x "$MOCK_BIN/gh"

    # Mock runner: capture the diff content it receives
    local diff_log
    diff_log="$(mktemp "$TMPDIR_TEST/runner-diff-commit-scoped.XXXXXX")"
    cat > "$MOCK_BIN/ci-llm-review-runner.sh" << MOCKEOF
#!/usr/bin/env bash
if [[ -n "\${DSO_CI_REVIEW_DIFF_PATH:-}" && -f "\${DSO_CI_REVIEW_DIFF_PATH}" ]]; then
    cat "\${DSO_CI_REVIEW_DIFF_PATH}" > "$diff_log"
fi
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/ci-llm-review-runner.sh"

    # Run the dispatcher from INSIDE the repo so git show can resolve the SHA
    (
        cd "$repo" || exit 1
        PATH="$MOCK_BIN:$PATH" \
        PR_NUMBER=99 \
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" > /dev/null 2>/dev/null || true
    )

    local diff_content
    diff_content="$(cat "$diff_log" 2>/dev/null || echo '')"
    local has_unreviewed="no" has_should_not="no"
    if echo "$diff_content" | grep -q 'unreviewed.py'; then has_unreviewed="yes"; fi
    if echo "$diff_content" | grep -q 'should_not_appear'; then has_should_not="yes"; fi

    assert_eq "test_dispatcher_commit_scoped_diff: diff contains unprovenanced commit's file" \
        "yes" "$has_unreviewed"
    assert_eq "test_dispatcher_commit_scoped_diff: diff does NOT contain gh pr diff output" \
        "no" "$has_should_not"

    rm -rf "$repo" "$artifact_dir" "$diff_log"
    assert_pass_if_clean "test_dispatcher_commit_scoped_diff"
}

# ── Test R3a (v4): commit-scoped diff empty fails closed ─────────────────────
# When unprovenanced-shas.txt contains SHAs that don't resolve in the local
# repo (shallow clone, missing object, etc.), commit-scoped diff is empty.
# v4 fails closed rather than falling back to full PR diff (which would
# re-review previously-approved code at giant-diff scale).
test_dispatcher_commit_scoped_diff_empty_fails_closed() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_commit_scoped_diff_empty_fails_closed: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_commit_scoped_diff_empty_fails_closed"
        return
    fi

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    # Seed with a SHA that doesn't resolve in any git repo
    _seed_artifacts "$artifact_dir" "unprovenanced" "0000000000000000000000000000000000000000"

    _make_mock_gh

    # Mock runner should NOT be called — dispatcher exits 1 before runner
    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-no-call.XXXXXX")"
    _make_mock_runner "$call_log"

    local exit_code=0
    PATH="$MOCK_BIN:$PATH" \
    PR_NUMBER=99 \
    DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" > /dev/null 2>/dev/null || exit_code=$?

    assert_eq "test_dispatcher_commit_scoped_diff_empty_fails_closed: exits non-zero on empty commit-scoped diff" \
        "1" "$exit_code"
    local runner_called="no"
    if [[ -f "$call_log" ]] && grep -q "runner-called" "$call_log" 2>/dev/null; then
        runner_called="yes"
    fi
    assert_eq "test_dispatcher_commit_scoped_diff_empty_fails_closed: runner NOT called (no fall-through to full PR diff)" \
        "no" "$runner_called"

    rm -rf "$artifact_dir" "$call_log"
    assert_pass_if_clean "test_dispatcher_commit_scoped_diff_empty_fails_closed"
}

# ── Test R7d (v4): dispatcher-side size cap routes to OVER_BOUND ──────────────
# When the commit-scoped diff exceeds the dispatcher's byte or file cap, the
# dispatcher routes to OVER_BOUND (exit 3) rather than dispatching to the
# runner. Caps are env-overridable; this test uses tiny override caps to
# trigger the gate deterministically.
test_dispatcher_size_cap_triggers_overbound() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_size_cap_triggers_overbound: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_size_cap_triggers_overbound"
        return
    fi

    # Create a real git repo with a sizeable commit
    local repo
    repo="$(mktemp -d)"
    git -C "$repo" init -b main > /dev/null 2>&1
    git -C "$repo" config user.name "Test" > /dev/null 2>&1
    git -C "$repo" config user.email "test@test.com" > /dev/null 2>&1
    printf 'initial\n' > "$repo/init.txt"
    git -C "$repo" add init.txt > /dev/null 2>&1
    git -C "$repo" commit -m "initial" > /dev/null 2>&1

    # Set up origin/main BEFORE the big commit so filter can resolve origin/main
    # but the big commit is NOT yet on it (R3a v4.1 dependency).
    git -C "$repo" init --bare "$repo/origin.git" > /dev/null 2>&1
    git -C "$repo" remote add origin "$repo/origin.git" > /dev/null 2>&1
    git -C "$repo" push origin main > /dev/null 2>&1

    # Add a commit with a substantial diff
    for i in 1 2 3 4 5; do
        printf 'line %s\n%s\n' "$i" "$(printf 'padding %.0s' {1..100})" > "$repo/file${i}.txt"
        git -C "$repo" add "file${i}.txt" > /dev/null 2>&1
    done
    git -C "$repo" commit -m "big commit" > /dev/null 2>&1
    local big_sha
    big_sha="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$artifact_dir/provenance-complete.marker"
    printf '%s\n' "$big_sha" > "$artifact_dir/unprovenanced-shas.txt"

    _make_mock_gh
    local call_log
    call_log="$(mktemp "$TMPDIR_TEST/runner-no-call.XXXXXX")"
    _make_mock_runner "$call_log"

    # Override caps to tiny values to trigger OVER_BOUND on the 5-file commit
    local exit_code=0
    (
        cd "$repo" || exit 1
        PATH="$MOCK_BIN:$PATH" \
        PR_NUMBER=99 \
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
        DSO_DISPATCH_FILES_CAP=2 \
            bash "$WRAPPER" > /dev/null 2>/dev/null
    ) || exit_code=$?

    # OVER_BOUND exits 3 → CI surfaces as failure (blocked)
    assert_eq "test_dispatcher_size_cap_triggers_overbound: exits 3 on cap exceedance" \
        "3" "$exit_code"
    local runner_called="no"
    if [[ -f "$call_log" ]] && grep -q "runner-called" "$call_log" 2>/dev/null; then
        runner_called="yes"
    fi
    assert_eq "test_dispatcher_size_cap_triggers_overbound: runner NOT called on cap exceedance" \
        "no" "$runner_called"

    rm -rf "$repo" "$artifact_dir" "$call_log"
    assert_pass_if_clean "test_dispatcher_size_cap_triggers_overbound"
}

# ── Test R3a v4.1: already-merged SHAs filtered from commit-scoped diff ──────
# When _DISPATCH_SCOPE_FILE contains SHAs already reachable from origin/main
# (e.g. squash-merged PR commits), they must be filtered out before the
# commit-scoped diff is generated. Otherwise the diff payload includes
# already-shipped code, potentially exploding to thousands of files.
test_dispatcher_filters_already_merged_shas() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_filters_already_merged_shas: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_filters_already_merged_shas"
        return
    fi

    # Build a repo with: main has commits A→B; branch has commits A→B→C.
    # Mark BOTH B and C as "unprovenanced" — the filter should remove B
    # (reachable from main) and only review C.
    local repo
    repo="$(mktemp -d)"
    git -C "$repo" init -b main > /dev/null 2>&1
    git -C "$repo" config user.name "Test" > /dev/null 2>&1
    git -C "$repo" config user.email "test@test.com" > /dev/null 2>&1
    printf 'A\n' > "$repo/a.txt"
    git -C "$repo" add a.txt > /dev/null 2>&1
    git -C "$repo" commit -m "A" > /dev/null 2>&1
    printf 'B\n' > "$repo/b.txt"
    git -C "$repo" add b.txt > /dev/null 2>&1
    git -C "$repo" commit -m "B (on main and branch)" > /dev/null 2>&1
    local merged_sha
    merged_sha="$(git -C "$repo" rev-parse HEAD)"

    # Create an origin remote so origin/main is resolvable
    git -C "$repo" init --bare "$repo/origin.git" > /dev/null 2>&1 || true
    (cd "$repo" && git remote add origin "$repo/origin.git" 2>/dev/null && git push origin main > /dev/null 2>&1) || true

    # Add C on branch (not on main)
    git -C "$repo" checkout -b branch > /dev/null 2>&1
    printf 'C\n' > "$repo/c.txt"
    git -C "$repo" add c.txt > /dev/null 2>&1
    git -C "$repo" commit -m "C (branch only)" > /dev/null 2>&1
    local unmerged_sha
    unmerged_sha="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$artifact_dir/provenance-complete.marker"
    # Seed with BOTH SHAs — filter should remove merged_sha
    printf '%s\n%s\n' "$merged_sha" "$unmerged_sha" > "$artifact_dir/unprovenanced-shas.txt"

    _make_mock_gh
    local diff_log
    diff_log="$(mktemp "$TMPDIR_TEST/runner-filtered-diff.XXXXXX")"
    cat > "$MOCK_BIN/ci-llm-review-runner.sh" << MOCKEOF
#!/usr/bin/env bash
if [[ -n "\${DSO_CI_REVIEW_DIFF_PATH:-}" && -f "\${DSO_CI_REVIEW_DIFF_PATH}" ]]; then
    cat "\${DSO_CI_REVIEW_DIFF_PATH}" > "$diff_log"
fi
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/ci-llm-review-runner.sh"

    (
        cd "$repo" || exit 1
        PATH="$MOCK_BIN:$PATH" \
        PR_NUMBER=99 \
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" > /dev/null 2>/dev/null || true
    )

    local diff_content
    diff_content="$(cat "$diff_log" 2>/dev/null || echo '')"
    # b.txt (already merged) should NOT appear; c.txt (unmerged) should appear
    local has_b="no" has_c="no"
    if echo "$diff_content" | grep -q 'b.txt'; then has_b="yes"; fi
    if echo "$diff_content" | grep -q 'c.txt'; then has_c="yes"; fi

    assert_eq "test_dispatcher_filters_already_merged_shas: c.txt (unmerged) in diff" \
        "yes" "$has_c"
    assert_eq "test_dispatcher_filters_already_merged_shas: b.txt (already merged) NOT in diff" \
        "no" "$has_b"

    rm -rf "$repo" "$artifact_dir" "$diff_log"
    assert_pass_if_clean "test_dispatcher_filters_already_merged_shas"
}

# ── Test R3a v4.1: unresolvable main ref fails closed (not unfiltered) ───────
# When origin/main can't be resolved (no remote, fresh clone), the dispatcher
# MUST fail closed rather than fall through to unfiltered explosive iteration.
test_dispatcher_unresolvable_main_fails_closed() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_unresolvable_main_fails_closed: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_unresolvable_main_fails_closed"
        return
    fi

    # Build a repo with NO origin remote
    local repo
    repo="$(mktemp -d)"
    git -C "$repo" init -b main > /dev/null 2>&1
    git -C "$repo" config user.name "Test" > /dev/null 2>&1
    git -C "$repo" config user.email "test@test.com" > /dev/null 2>&1
    printf 'A\n' > "$repo/a.txt"
    git -C "$repo" add a.txt > /dev/null 2>&1
    git -C "$repo" commit -m "A" > /dev/null 2>&1
    local sha
    sha="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$artifact_dir/provenance-complete.marker"
    printf '%s\n' "$sha" > "$artifact_dir/unprovenanced-shas.txt"

    _make_mock_gh
    local exit_code=0
    local output
    output=$(
        cd "$repo" || exit 1
        PATH="$MOCK_BIN:$PATH" \
        PR_NUMBER=99 \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || exit_code=$?

    assert_eq "test_dispatcher_unresolvable_main_fails_closed: exits 1 (not 0/3) when origin/main unresolvable" \
        "1" "$exit_code"
    assert_contains "test_dispatcher_unresolvable_main_fails_closed: error mentions remediation" \
        "not resolvable" "$output"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_dispatcher_unresolvable_main_fails_closed"
}

# ── Test R3a v4.1: shallow clone with unfixable remote fails closed ──────────
# When the dispatcher detects a shallow clone, it attempts self-healing via
# `git fetch --unshallow`. If that succeeds, filtering proceeds normally. If
# the remote is unreachable, dispatcher must fail closed rather than proceed
# with truncated rev-list (which would defeat the filter).
test_dispatcher_shallow_clone_fails_closed() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_shallow_clone_fails_closed: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_shallow_clone_fails_closed"
        return
    fi

    # Build a repo with a shallow marker BUT a bogus origin URL so
    # `git fetch --unshallow` can't succeed.
    local repo
    repo="$(mktemp -d)"
    git -C "$repo" init -b main > /dev/null 2>&1
    git -C "$repo" config user.name "Test" > /dev/null 2>&1
    git -C "$repo" config user.email "test@test.com" > /dev/null 2>&1
    printf 'commit A\n' > "$repo/a.txt"
    git -C "$repo" add a.txt > /dev/null 2>&1
    git -C "$repo" commit -m "A" > /dev/null 2>&1
    # Set up bogus origin and a fake origin/main ref so the "main resolvable"
    # check passes but "unshallow" fails.
    git -C "$repo" remote add origin "file:///nonexistent-bogus-path-${RANDOM}" > /dev/null 2>&1
    # Mirror HEAD as origin/main so rev-parse origin/main succeeds locally
    git -C "$repo" update-ref refs/remotes/origin/main HEAD > /dev/null 2>&1
    # Write shallow marker so dispatcher detects shallow state
    git -C "$repo" rev-parse HEAD > "$repo/.git/shallow"

    local sha
    sha="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$artifact_dir/provenance-complete.marker"
    printf '%s\n' "$sha" > "$artifact_dir/unprovenanced-shas.txt"

    _make_mock_gh
    local exit_code=0
    local output
    output=$(
        cd "$repo" || exit 1
        PATH="$MOCK_BIN:$PATH" \
        PR_NUMBER=99 \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || exit_code=$?

    assert_eq "test_dispatcher_shallow_clone_fails_closed: exits 1 when shallow+unfixable" \
        "1" "$exit_code"
    # Accept any fail-closed message that names the precondition:
    #   (a) "fetch --unshallow failed" (self-heal attempted, remote unreachable)
    #   (b) "still shallow" (self-heal ran but didn't change state)
    #   (c) "not resolvable" (origin/main missing — depends on test setup)
    local fail_msg="no"
    if echo "$output" | grep -qE "shallow|unshallow|not resolvable"; then
        fail_msg="yes"
    fi
    assert_eq "test_dispatcher_shallow_clone_fails_closed: error names a precondition" \
        "yes" "$fail_msg"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_dispatcher_shallow_clone_fails_closed"
}

# ── Test R3a v4.1: PR #425 regression — many merged + few unmerged ────────────
# Direct anchor against the bug being fixed. Seed scope with 50 already-merged
# SHAs + 2 unmerged SHAs; dispatched diff must contain only the 2 unmerged
# commits' changes, NOT all 52.
test_dispatcher_regression_pr425_giant_diff() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_regression_pr425_giant_diff: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_regression_pr425_giant_diff"
        return
    fi

    local repo
    repo="$(mktemp -d)"
    git -C "$repo" init -b main > /dev/null 2>&1
    git -C "$repo" config user.name "Test" > /dev/null 2>&1
    git -C "$repo" config user.email "test@test.com" > /dev/null 2>&1
    printf 'init\n' > "$repo/init.txt"
    git -C "$repo" add init.txt > /dev/null 2>&1
    git -C "$repo" commit -m "init" > /dev/null 2>&1

    # Create 50 commits on main, capture all SHAs
    local merged_shas=()
    for i in $(seq 1 50); do
        printf 'main commit %s\n' "$i" > "$repo/main_file_${i}.txt"
        git -C "$repo" add "main_file_${i}.txt" > /dev/null 2>&1
        git -C "$repo" commit -m "M${i}" > /dev/null 2>&1
        merged_shas+=("$(git -C "$repo" rev-parse HEAD)")
    done

    # Set up origin
    git -C "$repo" init --bare "$repo/origin.git" > /dev/null 2>&1
    git -C "$repo" remote add origin "$repo/origin.git" > /dev/null 2>&1
    git -C "$repo" push origin main > /dev/null 2>&1

    # Now add 2 commits on a branch (NOT on main)
    git -C "$repo" checkout -b feature > /dev/null 2>&1
    printf 'unmerged 1\n' > "$repo/unmerged_1.txt"
    git -C "$repo" add unmerged_1.txt > /dev/null 2>&1
    git -C "$repo" commit -m "U1" > /dev/null 2>&1
    local unmerged_sha_1
    unmerged_sha_1="$(git -C "$repo" rev-parse HEAD)"
    printf 'unmerged 2\n' > "$repo/unmerged_2.txt"
    git -C "$repo" add unmerged_2.txt > /dev/null 2>&1
    git -C "$repo" commit -m "U2" > /dev/null 2>&1
    local unmerged_sha_2
    unmerged_sha_2="$(git -C "$repo" rev-parse HEAD)"

    # Seed unprovenanced with ALL 52 SHAs — filter should reduce to 2
    local artifact_dir
    artifact_dir="$(mktemp -d)"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$artifact_dir/provenance-complete.marker"
    {
        printf '%s\n' "${merged_shas[@]}"
        printf '%s\n' "$unmerged_sha_1"
        printf '%s\n' "$unmerged_sha_2"
    } > "$artifact_dir/unprovenanced-shas.txt"

    _make_mock_gh
    local diff_log
    diff_log="$(mktemp "$TMPDIR_TEST/runner-regression-diff.XXXXXX")"
    cat > "$MOCK_BIN/ci-llm-review-runner.sh" << MOCKEOF
#!/usr/bin/env bash
if [[ -n "\${DSO_CI_REVIEW_DIFF_PATH:-}" && -f "\${DSO_CI_REVIEW_DIFF_PATH}" ]]; then
    cat "\${DSO_CI_REVIEW_DIFF_PATH}" > "$diff_log"
fi
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/ci-llm-review-runner.sh"

    (
        cd "$repo" || exit 1
        PATH="$MOCK_BIN:$PATH" \
        PR_NUMBER=99 \
        DSO_RUNNER_PATH="$MOCK_BIN/ci-llm-review-runner.sh" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" > /dev/null 2>/dev/null || true
    )

    # Dispatched diff must contain unmerged files but NOT any merged files
    local diff_content
    diff_content="$(cat "$diff_log" 2>/dev/null || echo '')"
    local has_unmerged_1="no" has_unmerged_2="no"
    if echo "$diff_content" | grep -q 'unmerged_1.txt'; then has_unmerged_1="yes"; fi
    if echo "$diff_content" | grep -q 'unmerged_2.txt'; then has_unmerged_2="yes"; fi

    # Count merged files that appear (must be 0)
    local merged_file_count
    merged_file_count="$(echo "$diff_content" | grep -c 'main_file_' || echo 0)"

    assert_eq "test_dispatcher_regression_pr425_giant_diff: unmerged_1 in diff" \
        "yes" "$has_unmerged_1"
    assert_eq "test_dispatcher_regression_pr425_giant_diff: unmerged_2 in diff" \
        "yes" "$has_unmerged_2"
    assert_eq "test_dispatcher_regression_pr425_giant_diff: ZERO merged files in diff" \
        "0" "$merged_file_count"

    rm -rf "$repo" "$artifact_dir" "$diff_log"
    assert_pass_if_clean "test_dispatcher_regression_pr425_giant_diff"
}

# ── Test R3a v4.1: all-merged scope skips review with clear conclusion ────────
# When all unprovenanced SHAs are reachable from origin/main, the filter
# removes everything; dispatcher emits skipped conclusion (don't fail-closed,
# don't re-review already-shipped code).
test_dispatcher_all_scope_merged_skips() {
    _snapshot_fail
    if [[ ! -f "$WRAPPER" ]]; then
        assert_eq "test_dispatcher_all_scope_merged_skips: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_dispatcher_all_scope_merged_skips"
        return
    fi

    local repo
    repo="$(mktemp -d)"
    git -C "$repo" init -b main > /dev/null 2>&1
    git -C "$repo" config user.name "Test" > /dev/null 2>&1
    git -C "$repo" config user.email "test@test.com" > /dev/null 2>&1
    printf 'A\n' > "$repo/a.txt"
    git -C "$repo" add a.txt > /dev/null 2>&1
    git -C "$repo" commit -m "A" > /dev/null 2>&1
    local merged_sha
    merged_sha="$(git -C "$repo" rev-parse HEAD)"

    git -C "$repo" init --bare "$repo/origin.git" > /dev/null 2>&1 || true
    (cd "$repo" && git remote add origin "$repo/origin.git" 2>/dev/null && git push origin main > /dev/null 2>&1) || true

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$artifact_dir/provenance-complete.marker"
    # Seed with ONLY the already-merged SHA
    printf '%s\n' "$merged_sha" > "$artifact_dir/unprovenanced-shas.txt"

    _make_mock_gh
    local output
    local exit_code=0
    output=$(
        cd "$repo" || exit 1
        PATH="$MOCK_BIN:$PATH" \
        PR_NUMBER=99 \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || exit_code=$?

    assert_eq "test_dispatcher_all_scope_merged_skips: exits 0 when all scope already merged" \
        "0" "$exit_code"
    assert_contains "test_dispatcher_all_scope_merged_skips: output contains CONCLUSION skipped" \
        "CONCLUSION: skipped" "$output"
    assert_contains "test_dispatcher_all_scope_merged_skips: output explains all-merged reason" \
        "already reachable from" "$output"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_dispatcher_all_scope_merged_skips"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_wrapper_exists
test_exit0_skips_runner
test_exit0_emits_skipped_conclusion
test_exit0_liveness_assertion_in_summary
test_exit1_invokes_runner
test_exit2_invokes_runner
test_exit3_blocks_ci
test_exit3_emits_over_bound_summary
test_dispatcher_no_marker_exits_1
test_dispatcher_marker_only_skipped
test_dispatcher_overbound_routes_correctly
test_dispatcher_unprovenanced_dispatches_runner
test_dispatcher_covered_list_from_artifact
test_dispatcher_supplies_diff_to_runner
test_dispatcher_commit_scoped_diff
test_dispatcher_commit_scoped_diff_empty_fails_closed
test_dispatcher_size_cap_triggers_overbound
test_dispatcher_filters_already_merged_shas
test_dispatcher_unresolvable_main_fails_closed
test_dispatcher_shallow_clone_fails_closed
test_dispatcher_regression_pr425_giant_diff
test_dispatcher_all_scope_merged_skips

print_summary
